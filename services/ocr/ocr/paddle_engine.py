from __future__ import annotations

import base64
import inspect
import io
import threading
import time
from pathlib import Path
from typing import Any

from .base import (
    BoundingBox,
    ImageInput,
    InvalidImageInputError,
    OcrEngine,
    OcrEngineError,
    OcrResult,
    OcrTextBlock,
)
from .config import OcrConfig


class PaddleOcrEngine(OcrEngine):
    """
    Concrete OcrEngine strategy backed by PaddleOCR (PP-OCRv4 Mobile).

    All PaddlePaddle/PaddleOCR dependencies, model weight initialization,
    image decoding, and receipt reading-order post-processing are strictly
    encapsulated within this module.
    """

    def __init__(
        self,
        config: OcrConfig | None = None,
        *,
        predictor: Any | None = None,
    ) -> None:
        self._config = config or OcrConfig.from_env()
        self._predictor = predictor
        self._lock = threading.Lock()

    @property
    def engine_name(self) -> str:
        return "paddleocr"

    @property
    def model_version(self) -> str:
        return f"{self._config.ocr_version}-{self._config.model_variant}"

    @property
    def is_loaded(self) -> bool:
        return self._predictor is not None

    def load(self) -> None:
        """Eagerly initialize PaddleOCR weights (once, at application startup)."""
        self._get_or_create_predictor()

    def _build_paddle_kwargs(self, lang: str) -> dict[str, Any]:
        """Build kwargs compatible with the installed PaddleOCR version for PP-OCRv4 Mobile."""
        desired: dict[str, Any] = {
            "ocr_version": self._config.ocr_version,
            "lang": lang,
            "use_angle_cls": self._config.use_angle_cls,
            "use_gpu": self._config.use_gpu,
            "enable_mkldnn": self._config.enable_mkldnn,
            "cpu_threads": self._config.cpu_threads,
            "det_limit_side_len": self._config.det_limit_side_len,
            "rec_batch_num": self._config.rec_batch_num,
            "drop_score": self._config.drop_score,
            "show_log": False,
        }
        if self._config.det_model_dir:
            desired["det_model_dir"] = self._config.det_model_dir
        if self._config.rec_model_dir:
            desired["rec_model_dir"] = self._config.rec_model_dir
        if self._config.cls_model_dir:
            desired["cls_model_dir"] = self._config.cls_model_dir
        return desired

    def _get_or_create_predictor(self) -> Any:
        if self._predictor is not None:
            return self._predictor

        with self._lock:
            if self._predictor is not None:
                return self._predictor

            try:
                from paddleocr import PaddleOCR  # type: ignore[import-untyped]
            except ImportError as exc:
                raise OcrEngineError(
                    "PaddleOCR dependencies are not installed. "
                    "Install 'paddlepaddle' and 'paddleocr' via services/ocr/requirements.txt."
                ) from exc

            # Filter kwargs if the installed paddleocr version restricts __init__ parameters
            sig = inspect.signature(PaddleOCR.__init__)
            accepts_var_kw = any(
                p.kind == inspect.Parameter.VAR_KEYWORD
                for p in sig.parameters.values()
            )

            def _filter(kw: dict[str, Any]) -> dict[str, Any]:
                if accepts_var_kw:
                    return kw
                return {k: v for k, v in kw.items() if k in sig.parameters}

            primary_lang = self._config.lang
            try:
                self._predictor = PaddleOCR(**_filter(self._build_paddle_kwargs(primary_lang)))
            except (ValueError, AssertionError, KeyError):
                # In some PaddleOCR releases 'tr' is grouped under 'latin'
                fallback_lang = "latin" if primary_lang == "tr" else "en"
                self._predictor = PaddleOCR(**_filter(self._build_paddle_kwargs(fallback_lang)))

            return self._predictor

    @staticmethod
    def _decode_image_to_ndarray(image_input: ImageInput) -> Any:
        """
        Convert supported ImageInput into a 3-channel RGB/BGR numpy.ndarray in memory.
        Never writes temporary files to disk (preserving NFR-2 / FR-2.3 privacy guarantees).
        """
        if image_input is None:
            raise InvalidImageInputError("image_input cannot be None")

        try:
            import numpy as np
            from PIL import Image, ImageOps
        except ImportError as exc:
            raise OcrEngineError(
                "Pillow and numpy are required for image preprocessing."
            ) from exc

        if isinstance(image_input, np.ndarray):
            if image_input.size == 0:
                raise InvalidImageInputError("Provided numpy image array is empty")
            return image_input

        if isinstance(image_input, Image.Image):
            img = ImageOps.exif_transpose(image_input).convert("RGB")
            return np.asarray(img)

        raw_bytes: bytes | None = None
        if isinstance(image_input, (bytes, bytearray)):
            raw_bytes = bytes(image_input)
        elif isinstance(image_input, Path):
            if not image_input.exists():
                raise InvalidImageInputError(f"Image path does not exist: {image_input}")
            raw_bytes = image_input.read_bytes()
        elif isinstance(image_input, str):
            stripped = image_input.strip()
            if not stripped:
                raise InvalidImageInputError("image_input string is empty")
            # Check if it's a data URI or base64 payload vs file path
            if stripped.startswith("data:image/") and "," in stripped:
                b64_part = stripped.split(",", 1)[1]
                try:
                    raw_bytes = base64.b64decode(b64_part, validate=False)
                except Exception as exc:
                    raise InvalidImageInputError("Invalid base64 data URI") from exc
            else:
                path_candidate = Path(stripped)
                if len(stripped) < 260 and path_candidate.exists() and path_candidate.is_file():
                    raw_bytes = path_candidate.read_bytes()
                else:
                    try:
                        raw_bytes = base64.b64decode(stripped, validate=True)
                    except Exception as exc:
                        raise InvalidImageInputError(
                            "String input is neither an existing file path nor valid base64"
                        ) from exc
        else:
            raise InvalidImageInputError(
                f"Unsupported image_input type: {type(image_input).__name__}"
            )

        if not raw_bytes:
            raise InvalidImageInputError("Image byte payload is empty")

        try:
            with Image.open(io.BytesIO(raw_bytes)) as pil_img:
                # Apply EXIF orientation for mobile camera captures
                transposed = ImageOps.exif_transpose(pil_img)
                rgb_img = transposed.convert("RGB")
                return np.asarray(rgb_img)
        except Exception as exc:
            raise InvalidImageInputError(f"Failed to decode image bytes: {exc}") from exc

    @staticmethod
    def _parse_raw_paddle_output(raw_output: Any, drop_score: float = 0.5) -> list[OcrTextBlock]:
        """
        Normalize PaddleOCR outputs across 2.x (`[[[box, (text, score)], ...]]`)
        and dictionary-based formats into OcrTextBlock instances.
        """
        if not raw_output:
            return []

        # Unwrap single-page batch list if nested: [ [ [box, (txt, conf)], ... ] ]
        lines = raw_output
        if (
            isinstance(lines, list)
            and len(lines) == 1
            and isinstance(lines[0], list)
            and (len(lines[0]) == 0 or isinstance(lines[0][0], (list, tuple, dict)))
        ):
            # Distinguish between a single detection `[box, (txt, conf)]` vs page list
            first = lines[0]
            if not (
                len(first) == 2
                and isinstance(first[1], (list, tuple))
                and len(first[1]) == 2
                and isinstance(first[1][0], str)
            ):
                lines = first

        if not lines:
            return []

        blocks: list[OcrTextBlock] = []
        for item in lines:
            if not item:
                continue
            if isinstance(item, dict):
                text = str(item.get("rec_text") or item.get("text") or "").strip()
                conf = float(item.get("rec_score") or item.get("confidence") or 0.0)
                raw_box = item.get("dt_polys") or item.get("bbox")
            elif isinstance(item, (list, tuple)) and len(item) >= 2:
                raw_box = item[0]
                rec = item[1]
                if isinstance(rec, (list, tuple)) and len(rec) >= 2:
                    text = str(rec[0]).strip()
                    conf = float(rec[1])
                else:
                    continue
            else:
                continue

            if not text or conf < drop_score:
                continue

            bbox: BoundingBox | None = None
            if isinstance(raw_box, (list, tuple)) and len(raw_box) >= 4:
                try:
                    bbox = [(float(pt[0]), float(pt[1])) for pt in raw_box[:4]]
                except (TypeError, ValueError, IndexError):
                    bbox = None

            blocks.append(OcrTextBlock(text=text, confidence=conf, bbox=bbox))

        return blocks

    @staticmethod
    def _reconstruct_receipt_lines(blocks: list[OcrTextBlock]) -> tuple[str, list[OcrTextBlock]]:
        """
        Sort OCR blocks in top-to-bottom, left-to-right order and merge blocks
        that lie on the same horizontal receipt row (e.g., item name on left, price on right).
        """
        if not blocks:
            return "", []

        def _box_metrics(b: OcrTextBlock) -> tuple[float, float, float]:
            if not b.bbox:
                return (0.0, 0.0, 20.0)
            xs = [pt[0] for pt in b.bbox]
            ys = [pt[1] for pt in b.bbox]
            y_center = (min(ys) + max(ys)) / 2.0
            x_min = min(xs)
            height = max(1.0, max(ys) - min(ys))
            return (y_center, x_min, height)

        annotated = [(b, *_box_metrics(b)) for b in blocks]
        # If none of the blocks have bounding boxes, preserve original order
        if all(b.bbox is None for b in blocks):
            raw_text = "\n".join(b.text for b in blocks)
            return raw_text, list(blocks)

        annotated.sort(key=lambda item: (item[1], item[2]))

        rows: list[list[tuple[OcrTextBlock, float, float, float]]] = []
        for entry in annotated:
            if not rows:
                rows.append([entry])
                continue
            current_row = rows[-1]
            avg_y = sum(e[1] for e in current_row) / len(current_row)
            avg_h = sum(e[3] for e in current_row) / len(current_row)
            threshold = max(8.0, avg_h * 0.55)
            if abs(entry[1] - avg_y) <= threshold:
                current_row.append(entry)
            else:
                rows.append([entry])

        ordered_blocks: list[OcrTextBlock] = []
        text_lines: list[str] = []
        for row in rows:
            row.sort(key=lambda item: item[2])  # left-to-right by x_min
            ordered_blocks.extend(item[0] for item in row)
            text_lines.append(" ".join(item[0].text for item in row))

        return "\n".join(text_lines), ordered_blocks

    def extract_text(self, image_input: ImageInput) -> OcrResult:
        start_ns = time.perf_counter_ns()
        img_array = self._decode_image_to_ndarray(image_input)

        try:
            predictor = self._get_or_create_predictor()
            try:
                raw_output = predictor.ocr(img_array, cls=self._config.use_angle_cls)
            except TypeError:
                # Newer PaddleOCR predictors may not accept `cls` in `.ocr()`
                raw_output = predictor.ocr(img_array)

            blocks = self._parse_raw_paddle_output(
                raw_output, drop_score=self._config.drop_score
            )
            raw_text, ordered_blocks = self._reconstruct_receipt_lines(blocks)

            avg_conf = (
                sum(b.confidence for b in ordered_blocks) / len(ordered_blocks)
                if ordered_blocks
                else 0.0
            )
            elapsed_ms = (time.perf_counter_ns() - start_ns) / 1_000_000.0

            return OcrResult(
                raw_text=raw_text,
                blocks=ordered_blocks,
                confidence=avg_conf,
                engine=self.engine_name,
                model_version=self.model_version,
                elapsed_ms=elapsed_ms,
                metadata={
                    "lang": self._config.lang,
                    "line_count": len(raw_text.splitlines()) if raw_text else 0,
                    "block_count": len(ordered_blocks),
                },
            )
        except OcrEngineError:
            raise
        except Exception as exc:
            raise OcrEngineError(f"PaddleOCR inference failed: {exc}") from exc
        finally:
            # Explicit memory cleanup reference drop (FR-2.3 / NFR-2)
            del img_array

