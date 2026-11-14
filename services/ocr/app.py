from __future__ import annotations

import logging
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from ocr.base import InvalidImageInputError, OcrEngine, OcrEngineError, OcrResult
from ocr.config import OcrConfig
from ocr.factory import UnknownOcrEngineError, default_registry, get_ocr_engine

logger = logging.getLogger("fissio.ocr")


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Load the default engine's model weights once at startup, not per request."""
    try:
        engine = get_ocr_engine()
        await run_in_threadpool(engine.load)
        logger.info("OCR engine '%s' loaded", engine.engine_name)
    except NotImplementedError as exc:
        logger.warning("Default OCR engine is not ready: %s", exc)
    except Exception:
        # Service stays up; the model is retried lazily on first request.
        logger.exception("OCR engine warm-up failed")
    yield


app = FastAPI(
    title="Fissio OCR Service",
    description="Modular Receipt OCR Microservice using Strategy Pattern & Factory Registry",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-OCR-Engine"],
)


class Base64OcrRequest(BaseModel):
    image_base64: str = Field(..., description="Base64-encoded receipt image (JPEG/PNG/WebP)")
    engine: str | None = Field(
        default=None,
        description="Optional request-level OCR engine override (e.g., 'paddleocr', 'custom')",
    )


def resolve_ocr_engine(
    engine_query: str | None = Query(
        default=None,
        alias="engine",
        description="Optional OCR engine name override",
    ),
    engine_header: str | None = Header(
        default=None,
        alias="X-OCR-Engine",
        description="Optional OCR engine header override",
    ),
) -> OcrEngine:
    """
    FastAPI Dependency that resolves the requested OcrEngine via the Factory Registry.
    Priority:
      1. Query parameter (`?engine=...`)
      2. HTTP Header (`X-OCR-Engine: ...`)
      3. Application environment configuration (`OCR_ENGINE`, defaults to `paddleocr`)
    """
    selected = engine_query or engine_header
    try:
        return get_ocr_engine(engine_name=selected)
    except UnknownOcrEngineError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/health")
def health() -> dict[str, Any]:
    cfg = OcrConfig.from_env()
    try:
        active = get_ocr_engine()
        active_name, model_loaded = active.engine_name, active.is_loaded
    except OcrEngineError:
        active_name, model_loaded = cfg.active_engine, False
    return {
        "service": "ocr",
        "status": "ok",
        "active_engine": active_name,
        "model_loaded": model_loaded,
        "default_engine": cfg.active_engine,
        "available_engines": default_registry.available_engines(),
        "time": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/ocr/engines")
def list_engines() -> dict[str, Any]:
    cfg = OcrConfig.from_env()
    return {
        "default_engine": cfg.active_engine,
        "available_engines": default_registry.available_engines(),
    }


@app.post("/ocr/extract")
async def extract_from_json(
    payload: Base64OcrRequest,
    engine: OcrEngine = Depends(resolve_ocr_engine),
) -> dict[str, Any]:
    """
    Extract receipt text from a base64-encoded image payload.
    Depends strictly on the abstract `OcrEngine` interface.
    """
    active_engine = engine
    if payload.engine:
        try:
            active_engine = get_ocr_engine(engine_name=payload.engine)
        except UnknownOcrEngineError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    img_b64 = payload.image_base64
    try:
        result = await run_in_threadpool(active_engine.extract_text, img_b64)
        return result.to_dict()
    except InvalidImageInputError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except NotImplementedError as exc:
        raise HTTPException(status_code=501, detail=str(exc)) from exc
    except OcrEngineError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    finally:
        # Discard reference immediately in accordance with NFR-2 / FR-2.3
        del img_b64


@app.post("/ocr/extract/upload")
async def extract_from_upload(
    file: UploadFile = File(..., description="Receipt image file"),
    engine_form: str | None = Form(default=None, alias="engine"),
    engine: OcrEngine = Depends(resolve_ocr_engine),
) -> dict[str, Any]:
    """
    Extract receipt text from a multipart file upload in memory.
    The uploaded image buffer is never persisted to disk and is released immediately.
    """
    active_engine = engine
    if engine_form:
        try:
            active_engine = get_ocr_engine(engine_name=engine_form)
        except UnknownOcrEngineError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    raw_bytes = await file.read()
    try:
        if not raw_bytes:
            raise HTTPException(status_code=400, detail="Uploaded file is empty")
        if len(raw_bytes) > 15 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="Image exceeds 15MB limit")
        result = await run_in_threadpool(active_engine.extract_text, raw_bytes)
        return result.to_dict()
    except InvalidImageInputError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except NotImplementedError as exc:
        raise HTTPException(status_code=501, detail=str(exc)) from exc
    except OcrEngineError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    finally:
        await file.close()
        del raw_bytes


def _to_parse_response(result: OcrResult, elapsed_ms: float) -> dict[str, Any]:
    """Compact response for `/ocr/parse`: integer pixel coordinates, one entry per text line."""
    lines = []
    for block in result.blocks:
        bbox = [[int(round(x)), int(round(y))] for x, y in block.bbox] if block.bbox else []
        lines.append(
            {"text": block.text, "confidence": round(float(block.confidence), 4), "bbox": bbox}
        )
    return {
        "engine": result.engine,
        "processing_time_ms": round(elapsed_ms, 1),
        "lines": lines,
    }


@app.post("/ocr/parse")
async def parse_upload(
    file: UploadFile = File(..., description="Receipt image file"),
    engine: OcrEngine = Depends(resolve_ocr_engine),
) -> dict[str, Any]:
    """
    multipart/form-data image -> `{engine, processing_time_ms, lines[{text, confidence, bbox}]}`.
    The image is read into RAM only (never written to disk) and inference runs in a threadpool.
    """
    raw_bytes = await file.read()
    try:
        if not raw_bytes:
            raise HTTPException(status_code=400, detail="Uploaded file is empty")
        if len(raw_bytes) > 15 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="Image exceeds 15MB limit")
        started = time.perf_counter()
        result = await run_in_threadpool(engine.extract_text, raw_bytes)
        return _to_parse_response(result, (time.perf_counter() - started) * 1000.0)
    except InvalidImageInputError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except NotImplementedError as exc:
        raise HTTPException(status_code=501, detail=str(exc)) from exc
    except OcrEngineError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    finally:
        await file.close()
        del raw_bytes


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8080"))
    uvicorn.run("app:app", host="0.0.0.0", port=port)

