from __future__ import annotations

import time
from typing import Any

from .base import (
    ImageInput,
    InvalidImageInputError,
    OcrEngine,
    OcrEngineError,
    OcrResult,
    OcrTextBlock,
)
from .config import OcrConfig


class CustomOcrEngine(OcrEngine):
    """
    Placeholder / Stub Strategy for a future in-house custom OCR model
    (e.g., ONNX Runtime, TorchScript, or TFLite receipt-specialized CRNN/Transformer).

    Designed for plug-and-play integration: replace `_load_model` and `_run_inference`
    without modifying any API endpoint, factory, or business logic.
    """

    def __init__(
        self,
        config: OcrConfig | None = None,
        *,
        model_path: str | None = None,
        device: str | None = None,
        allow_stub_fallback: bool = False,
    ) -> None:
        self._config = config or OcrConfig.from_env()
        self._model_path = model_path or self._config.custom_model_path
        self._device = device or self._config.custom_device
        self._allow_stub_fallback = allow_stub_fallback
        self._model: Any | None = None

    @property
    def engine_name(self) -> str:
        return "custom"

    @property
    def model_version(self) -> str:
        return "fissio-custom-ocr-v1-stub"

    @property
    def is_loaded(self) -> bool:
        return self._model is not None

    def load(self) -> None:
        self._load_model()

    def _load_model(self) -> Any:
        """
        Hook for loading custom model weights (e.g., onnxruntime.InferenceSession or torch.jit.load).
        """
        if self._model is not None:
            return self._model
        if not self._model_path and not self._allow_stub_fallback:
            raise NotImplementedError(
                "CustomOcrEngine is a plug-and-play stub. Provide CUSTOM_OCR_MODEL_PATH "
                "and implement _run_inference() or enable allow_stub_fallback for testing."
            )
        self._model = {"model_path": self._model_path, "device": self._device}
        return self._model

    def _preprocess(self, image_input: ImageInput) -> Any:
        """Hook for custom tensor normalization, resizing, and binarization."""
        if image_input is None or (isinstance(image_input, (bytes, bytearray, str)) and len(image_input) == 0):
            raise InvalidImageInputError("image_input cannot be empty")
        return image_input

    def _run_inference(self, preprocessed_input: Any) -> list[OcrTextBlock]:
        """Hook for running forward pass and decoding character logits."""
        if self._allow_stub_fallback:
            return [
                OcrTextBlock(
                    text="[CUSTOM_OCR_STUB]",
                    confidence=1.0,
                    bbox=[(0.0, 0.0), (100.0, 0.0), (100.0, 20.0), (0.0, 20.0)],
                )
            ]
        raise NotImplementedError(
            "CustomOcrEngine._run_inference() is not yet implemented for production weights."
        )

    def extract_text(self, image_input: ImageInput) -> OcrResult:
        start_ns = time.perf_counter_ns()
        tensor = self._preprocess(image_input)
        try:
            self._load_model()
            blocks = self._run_inference(tensor)
            raw_text = "\n".join(b.text for b in blocks)
            avg_conf = (
                sum(b.confidence for b in blocks) / len(blocks) if blocks else 0.0
            )
            elapsed_ms = (time.perf_counter_ns() - start_ns) / 1_000_000.0
            return OcrResult(
                raw_text=raw_text,
                blocks=blocks,
                confidence=avg_conf,
                engine=self.engine_name,
                model_version=self.model_version,
                elapsed_ms=elapsed_ms,
                metadata={
                    "device": self._device,
                    "model_path": self._model_path,
                    "stub": self._allow_stub_fallback,
                },
            )
        except (InvalidImageInputError, NotImplementedError, OcrEngineError):
            raise
        except Exception as exc:
            raise OcrEngineError(f"CustomOcrEngine failed: {exc}") from exc
        finally:
            del tensor

    def health_check(self) -> dict[str, Any]:
        return {
            "engine": self.engine_name,
            "model_version": self.model_version,
            "ready": bool(self._model_path or self._allow_stub_fallback),
            "stub": True,
        }

