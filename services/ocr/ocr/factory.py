from __future__ import annotations

import threading
from typing import Callable, Iterable

from .base import OcrEngine, OcrEngineError
from .config import OcrConfig
from .custom_engine import CustomOcrEngine
from .paddle_engine import PaddleOcrEngine

EngineBuilder = Callable[[OcrConfig], OcrEngine]


class UnknownOcrEngineError(OcrEngineError):
    """Raised when a requested OCR engine identifier is not registered in the factory."""


class OcrEngineFactory:
    """
    Extensible Provider Registry & Factory for OCR Engines (Strategy Pattern).

    Supports both:
    - Application-level default selection via `OcrConfig.active_engine` (`OCR_ENGINE` env var).
    - Request-level runtime selection by passing `engine_name` to `get_engine()`.
    """

    def __init__(self) -> None:
        self._builders: dict[str, EngineBuilder] = {}
        self._aliases: dict[str, str] = {}
        self._instances: dict[str, OcrEngine] = {}
        self._lock = threading.RLock()

    def register(
        self,
        name: str,
        builder: EngineBuilder,
        *,
        aliases: Iterable[str] = (),
    ) -> None:
        """Register an OcrEngine builder under a canonical name and optional aliases."""
        canonical = name.strip().lower()
        if not canonical:
            raise ValueError("Engine name cannot be empty")
        with self._lock:
            self._builders[canonical] = builder
            self._aliases[canonical] = canonical
            for alias in aliases:
                norm_alias = alias.strip().lower()
                if norm_alias:
                    self._aliases[norm_alias] = canonical
            self._instances.pop(canonical, None)

    def resolve_canonical_name(
        self,
        engine_name: str | None = None,
        config: OcrConfig | None = None,
    ) -> str:
        cfg = config or OcrConfig.from_env()
        requested = (engine_name or cfg.active_engine or "paddleocr").strip().lower()
        with self._lock:
            canonical = self._aliases.get(requested)
            if canonical is None or canonical not in self._builders:
                available = ", ".join(sorted(self._builders.keys()))
                raise UnknownOcrEngineError(
                    f"Unknown OCR engine '{requested}'. Available engines: [{available}]"
                )
            return canonical

    def get_engine(
        self,
        engine_name: str | None = None,
        config: OcrConfig | None = None,
        *,
        use_cache: bool = True,
    ) -> OcrEngine:
        """
        Resolve and return an OcrEngine instance.

        Args:
            engine_name: Optional runtime override ('paddleocr', 'custom', etc.).
                         Falls back to OcrConfig.active_engine (default 'paddleocr').
            config: Optional OcrConfig override.
            use_cache: If True, reuses a singleton instance per canonical engine name.
        """
        cfg = config or OcrConfig.from_env()
        canonical = self.resolve_canonical_name(engine_name, cfg)

        if not use_cache:
            with self._lock:
                builder = self._builders[canonical]
            return builder(cfg)

        with self._lock:
            if canonical not in self._instances:
                builder = self._builders[canonical]
                self._instances[canonical] = builder(cfg)
            return self._instances[canonical]

    def available_engines(self) -> list[str]:
        with self._lock:
            return sorted(self._builders.keys())

    def clear_cache(self) -> None:
        with self._lock:
            self._instances.clear()


# Global default registry pre-populated with built-in OCR strategies
default_registry = OcrEngineFactory()

default_registry.register(
    "paddleocr",
    lambda cfg: PaddleOcrEngine(config=cfg),
    aliases=("paddle", "ppocr", "pp-ocrv4", "pp-ocrv4-mobile"),
)

default_registry.register(
    "custom",
    lambda cfg: CustomOcrEngine(config=cfg),
    aliases=("custom_ocr", "inhouse", "fissio_custom"),
)


def register_ocr_engine(
    name: str,
    builder: EngineBuilder,
    *,
    aliases: Iterable[str] = (),
) -> None:
    """Register a new OCR engine strategy into the global registry."""
    default_registry.register(name, builder, aliases=aliases)


def get_ocr_engine(
    engine_name: str | None = None,
    config: OcrConfig | None = None,
    *,
    use_cache: bool = True,
) -> OcrEngine:
    """Resolve an OcrEngine instance from the global registry."""
    return default_registry.get_engine(
        engine_name=engine_name,
        config=config,
        use_cache=use_cache,
    )

