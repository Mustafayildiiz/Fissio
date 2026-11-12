from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

# Ensure the package root is importable when executed directly
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ocr import (
    CustomOcrEngine,
    ImageInput,
    InvalidImageInputError,
    OcrConfig,
    OcrEngine,
    OcrEngineFactory,
    OcrResult,
    OcrTextBlock,
    PaddleOcrEngine,
    UnknownOcrEngineError,
    get_ocr_engine,
)


class _FakePaddlePredictor:
    """
    Simulates PP-OCRv4 Mobile output on a sample Turkish supermarket receipt.
    Notice that item names and prices are separate horizontal bounding boxes on the same row.
    """

    def ocr(self, img: Any, cls: bool = True) -> list[list[Any]]:
        return [
            [
                # Header row (y ~ 20)
                [[[40, 15], [220, 15], [220, 35], [40, 35]], ("BIM BIRLESIK MAGAZALAR A.S.", 0.98)],
                # Date row (y ~ 55)
                [[[40, 50], [180, 50], [180, 68], [40, 68]], ("TARIH: 09.11.2026", 0.96)],
                # Item 1: left column (name) + right column (price) on same y ~ 100
                [[[40, 92], [160, 92], [160, 110], [40, 110]], ("SUT 1L TAM YAGLI", 0.95)],
                [[[240, 93], [300, 93], [300, 111], [240, 111]], ("34,50", 0.97)],
                # Item 2: left column (name) + right column (price) on same y ~ 130
                [[[40, 122], [150, 122], [150, 140], [40, 140]], ("EKMEK 500G", 0.94)],
                [[[240, 124], [300, 124], [300, 141], [240, 141]], ("15,00", 0.99)],
                # Low-confidence noise that should be filtered out (< 0.50)
                [[[10, 150], [30, 150], [30, 160], [10, 160]], ("~#", 0.21)],
                # Total row (y ~ 180): left label + right amount
                [[[40, 172], [130, 172], [130, 192], [40, 192]], ("TOPLAM", 0.99)],
                [[[230, 173], [300, 173], [300, 193], [230, 193]], ("*49,50", 0.98)],
            ]
        ]


class OcrSubsystemTestSuite(unittest.TestCase):
    def test_interface_cannot_be_instantiated_directly(self) -> None:
        with self.assertRaises(TypeError):
            OcrEngine()  # type: ignore[abstract]

    def test_factory_defaults_to_paddleocr_and_resolves_aliases(self) -> None:
        factory = OcrEngineFactory()
        factory.register(
            "paddleocr",
            lambda cfg: PaddleOcrEngine(config=cfg, predictor=_FakePaddlePredictor()),
            aliases=("paddle", "pp-ocrv4"),
        )
        factory.register(
            "custom",
            lambda cfg: CustomOcrEngine(config=cfg, allow_stub_fallback=True),
            aliases=("inhouse",),
        )

        # Default resolution (OCR_ENGINE defaults to 'paddleocr')
        default_engine = factory.get_engine()
        self.assertIsInstance(default_engine, PaddleOcrEngine)
        self.assertEqual(default_engine.engine_name, "paddleocr")
        self.assertEqual(default_engine.model_version, "PP-OCRv4-mobile")

        # Alias resolution returns cached singleton
        alias_engine = factory.get_engine("pp-ocrv4")
        self.assertIs(default_engine, alias_engine)

        # Runtime switch to custom engine
        custom_engine = factory.get_engine("inhouse")
        self.assertIsInstance(custom_engine, CustomOcrEngine)
        self.assertEqual(custom_engine.engine_name, "custom")

        # Unknown engine raises UnknownOcrEngineError
        with self.assertRaises(UnknownOcrEngineError):
            factory.get_engine("non_existent_ocr")

    def test_env_configuration_switches_active_engine(self) -> None:
        with patch.dict(os.environ, {"OCR_ENGINE": "custom", "OCR_LANG": "tr"}):
            cfg = OcrConfig.from_env()
            self.assertEqual(cfg.active_engine, "custom")
            engine = get_ocr_engine(config=cfg, use_cache=False)
            self.assertIsInstance(engine, CustomOcrEngine)

    def test_paddle_ocr_extraction_and_receipt_line_reconstruction(self) -> None:
        engine = PaddleOcrEngine(
            config=OcrConfig(ocr_version="PP-OCRv4", model_variant="mobile", lang="tr"),
            predictor=_FakePaddlePredictor(),
        )

        # Provide a synthetic 16x16 RGB image buffer (or mock _decode_image_to_ndarray if PIL/numpy unavailable)
        with patch.object(
            PaddleOcrEngine,
            "_decode_image_to_ndarray",
            return_value=[[0, 0, 0]],
        ):
            result: OcrResult = engine.extract_text(b"fake_jpeg_bytes")

        self.assertFalse(result.is_empty)
        self.assertEqual(result.engine, "paddleocr")
        self.assertEqual(result.model_version, "PP-OCRv4-mobile")
        self.assertEqual(len(result.blocks), 7)  # 8 raw boxes minus 1 low-confidence noise box
        self.assertGreater(result.confidence, 0.95)

        expected_lines = [
            "BIM BIRLESIK MAGAZALAR A.S.",
            "TARIH: 09.11.2026",
            "SUT 1L TAM YAGLI 34,50",
            "EKMEK 500G 15,00",
            "TOPLAM *49,50",
        ]
        self.assertEqual(result.raw_text.splitlines(), expected_lines)

    def test_custom_ocr_engine_stub_and_extensibility(self) -> None:
        # 1. Unconfigured stub raises NotImplementedError cleanly
        unconfigured = CustomOcrEngine(allow_stub_fallback=False)
        with self.assertRaises(NotImplementedError):
            unconfigured.extract_text(b"sample_image_bytes")

        # 2. Stub fallback mode works without touching caller code
        stub_engine = CustomOcrEngine(allow_stub_fallback=True)
        res = stub_engine.extract_text(b"sample_image_bytes")
        self.assertEqual(res.engine, "custom")
        self.assertEqual(res.raw_text, "[CUSTOM_OCR_STUB]")

        # 3. Plug-and-play subclassing for an in-house model
        class InHouseCrnnEngine(CustomOcrEngine):
            @property
            def model_version(self) -> str:
                return "fissio-crnn-tr-v2"

            def _load_model(self) -> Any:
                return "loaded_weights"

            def _run_inference(self, preprocessed_input: ImageInput) -> list[OcrTextBlock]:
                return [OcrTextBlock(text="MIGROS TICARET A.S.\nTOPLAM 250,00", confidence=0.99)]

        factory = OcrEngineFactory()
        factory.register("inhouse_v2", lambda cfg: InHouseCrnnEngine(config=cfg))
        resolved = factory.get_engine("inhouse_v2")
        out = resolved.extract_text(b"receipt_bytes")
        self.assertEqual(out.model_version, "fissio-crnn-tr-v2")
        self.assertIn("MIGROS", out.raw_text)

    def test_invalid_image_input_raises_error(self) -> None:
        stub = CustomOcrEngine(allow_stub_fallback=True)
        with self.assertRaises(InvalidImageInputError):
            stub.extract_text(b"")


if __name__ == "__main__":
    print("Running Fissio OCR Subsystem verification suite...")
    unittest.main(verbosity=2)

