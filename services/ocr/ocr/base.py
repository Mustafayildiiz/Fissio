from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Union

# Supported input types for OCR extraction:
# - bytes / bytearray: raw image bytes (JPEG, PNG, WebP, etc.)
# - str / Path: file system path or base64-encoded image string
# - Any: numpy.ndarray or PIL.Image.Image (kept generic to avoid leaking heavy CV deps into the interface)
ImageInput = Union[bytes, bytearray, str, Path, Any]

BoundingBox = list[tuple[float, float]]


@dataclass(frozen=True)
class OcrTextBlock:
    """Represents a single detected and recognized text line/region."""

    text: str
    confidence: float
    bbox: BoundingBox | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "text": self.text,
            "confidence": round(float(self.confidence), 4),
            "bbox": [list(pt) for pt in self.bbox] if self.bbox is not None else None,
        }


@dataclass(frozen=True)
class OcrResult:
    """Standardized output contract returned by every OcrEngine implementation."""

    raw_text: str
    blocks: list[OcrTextBlock] = field(default_factory=list)
    confidence: float = 0.0
    engine: str = "unknown"
    model_version: str = "unknown"
    elapsed_ms: float = 0.0
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def is_empty(self) -> bool:
        return len(self.raw_text.strip()) == 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "raw_text": self.raw_text,
            "blocks": [b.to_dict() for b in self.blocks],
            "confidence": round(float(self.confidence), 4),
            "engine": self.engine,
            "model_version": self.model_version,
            "elapsed_ms": round(float(self.elapsed_ms), 2),
            "is_empty": self.is_empty,
            "metadata": self.metadata,
        }


class OcrEngineError(Exception):
    """Base exception raised when an OCR engine fails to initialize or run inference."""


class InvalidImageInputError(OcrEngineError):
    """Raised when the provided image_input cannot be decoded or is empty."""


class OcrEngine(ABC):
    """
    Strategy Interface for Optical Character Recognition (OCR) engines.

    All concrete OCR providers (e.g., PaddleOcrEngine, CustomOcrEngine) MUST
    implement this abstract base class so upstream services, controllers, and
    pipelines remain strictly decoupled from underlying CV/DL frameworks.
    """

    @property
    @abstractmethod
    def engine_name(self) -> str:
        """Unique identifier of the OCR engine (e.g., 'paddleocr', 'custom')."""

    @property
    @abstractmethod
    def model_version(self) -> str:
        """Identifier of the underlying model architecture/weights (e.g., 'PP-OCRv4-mobile')."""

    @abstractmethod
    def extract_text(self, image_input: ImageInput) -> OcrResult:
        """
        Run OCR inference on the given image input and return a standardized OcrResult.

        Args:
            image_input: Raw image bytes, file path, base64 string, PIL.Image, or numpy ndarray.

        Returns:
            OcrResult containing reconstructed reading-order raw_text, individual
            OcrTextBlock items with bounding boxes and confidence scores, and timing metadata.

        Raises:
            InvalidImageInputError: If image_input is empty or cannot be decoded.
            OcrEngineError: If inference fails.
        """

    def health_check(self) -> dict[str, Any]:
        """Return operational metadata for health and readiness probes."""
        return {
            "engine": self.engine_name,
            "model_version": self.model_version,
            "ready": True,
        }

