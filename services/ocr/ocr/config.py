from __future__ import annotations

import os
from dataclasses import dataclass


def _env_bool(key: str, default: bool = False) -> bool:
    val = os.getenv(key)
    if val is None:
        return default
    return val.strip().lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class OcrConfig:
    """
    Application-level configuration for the OCR subsystem.
    Values are resolved from environment variables with sensible defaults
    targeting PP-OCRv4 Mobile on CPU.
    """

    active_engine: str = "paddleocr"
    ocr_version: str = "PP-OCRv4"
    model_variant: str = "mobile"
    lang: str = "tr"
    use_angle_cls: bool = True
    use_gpu: bool = False
    enable_mkldnn: bool = True
    cpu_threads: int = 4
    det_limit_side_len: int = 960
    rec_batch_num: int = 6
    drop_score: float = 0.5
    det_model_dir: str | None = None
    rec_model_dir: str | None = None
    cls_model_dir: str | None = None

    # Custom OCR Engine settings
    custom_model_path: str | None = None
    custom_device: str = "cpu"
    custom_confidence_threshold: float = 0.5

    @classmethod
    def from_env(cls) -> OcrConfig:
        return cls(
            active_engine=os.getenv("OCR_ENGINE", "paddleocr").strip().lower(),
            ocr_version=os.getenv("OCR_VERSION", "PP-OCRv4").strip(),
            model_variant=os.getenv("OCR_MODEL_VARIANT", "mobile").strip().lower(),
            lang=os.getenv("OCR_LANG", "tr").strip().lower(),
            use_angle_cls=_env_bool("OCR_USE_ANGLE_CLS", True),
            use_gpu=_env_bool("OCR_USE_GPU", False),
            enable_mkldnn=_env_bool("OCR_ENABLE_MKLDNN", True),
            cpu_threads=int(os.getenv("OCR_CPU_THREADS", "4")),
            det_limit_side_len=int(os.getenv("OCR_DET_LIMIT_SIDE_LEN", "960")),
            rec_batch_num=int(os.getenv("OCR_REC_BATCH_NUM", "6")),
            drop_score=float(os.getenv("OCR_DROP_SCORE", "0.5")),
            det_model_dir=os.getenv("OCR_DET_MODEL_DIR") or None,
            rec_model_dir=os.getenv("OCR_REC_MODEL_DIR") or None,
            cls_model_dir=os.getenv("OCR_CLS_MODEL_DIR") or None,
            custom_model_path=os.getenv("CUSTOM_OCR_MODEL_PATH") or None,
            custom_device=os.getenv("CUSTOM_OCR_DEVICE", "cpu").strip(),
            custom_confidence_threshold=float(
                os.getenv("CUSTOM_OCR_CONFIDENCE_THRESHOLD", "0.5")
            ),
        )

