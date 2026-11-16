"""Bir fotoğrafın ham OCR kutularını (metin + poligon) JSON olarak yazar (hata ayıklama)."""
import dataclasses
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent))
from ocr.config import OcrConfig  # noqa: E402
from ocr.paddle_engine import PaddleOcrEngine  # noqa: E402

name = sys.argv[1]
cfg = dataclasses.replace(OcrConfig.from_env(), dedupe=False)
eng = PaddleOcrEngine(config=cfg)
res = eng.extract_text((ROOT / "receipts" / name).read_bytes())
out = [{"text": b.text, "conf": round(b.confidence, 3), "bbox": b.bbox} for b in res.blocks]
(ROOT / f"blocks_{Path(name).stem}.json").write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
print(len(out), "blocks")
