"""Girdi sınırları: piksel üst sınırı (decompression bomb) ve istek boyutu denetimi."""
from __future__ import annotations

import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ocr import InvalidImageInputError, OcrConfig, PaddleOcrEngine


def _png_bytes(width: int, height: int) -> bytes:
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (width, height), (255, 255, 255)).save(buf, format="PNG")
    return buf.getvalue()


class PixelLimitTests(unittest.TestCase):
    def _engine(self, max_pixels: int) -> PaddleOcrEngine:
        return PaddleOcrEngine(
            config=OcrConfig(max_image_pixels=max_pixels), predictor=object()
        )

    def test_image_within_limit_is_decoded(self) -> None:
        arr = self._engine(10_000)._decode_image_to_ndarray(_png_bytes(50, 50))
        self.assertEqual(arr.shape[:2], (50, 50))

    def test_image_over_limit_is_rejected_before_decode(self) -> None:
        # 200x200 = 40.000 px > 10.000 px sınırı
        with self.assertRaises(InvalidImageInputError) as ctx:
            self._engine(10_000)._decode_image_to_ndarray(_png_bytes(200, 200))
        self.assertIn("too large", str(ctx.exception))

    def test_zero_disables_limit(self) -> None:
        arr = self._engine(0)._decode_image_to_ndarray(_png_bytes(200, 200))
        self.assertEqual(arr.shape[:2], (200, 200))


class RequestSizeTests(unittest.TestCase):
    def test_content_length_guard(self) -> None:
        from fastapi import HTTPException

        import app as ocr_app

        # başlık yok / sınır içinde -> geçer
        self.assertIsNone(ocr_app.limit_request_size(None))
        self.assertIsNone(ocr_app.limit_request_size(1024))
        # sınırın üstünde -> 413
        with self.assertRaises(HTTPException) as ctx:
            ocr_app.limit_request_size(ocr_app.MAX_REQUEST_BYTES + 1)
        self.assertEqual(ctx.exception.status_code, 413)

    def test_base64_field_has_length_cap(self) -> None:
        from pydantic import ValidationError

        import app as ocr_app

        with self.assertRaises(ValidationError):
            ocr_app.Base64OcrRequest(image_base64="A" * (ocr_app.MAX_BASE64_CHARS + 1))
        ocr_app.Base64OcrRequest(image_base64="A" * 16)


class CorsTests(unittest.TestCase):
    def test_no_cors_middleware_by_default(self) -> None:
        # OCR iç ağa özeldir ve kimliksizdir: tarayıcı kaynaklarına CORS açılmaz (OCR_CORS_ORIGINS ile açılabilir).
        import app as ocr_app

        names = [m.cls.__name__ for m in ocr_app.app.user_middleware]
        self.assertNotIn("CORSMiddleware", names)


class InferenceSerializationTests(unittest.TestCase):
    def test_predictor_is_never_called_concurrently(self) -> None:
        # Paddle predictor iş parçacığı güvenli değil (eşzamanlı çağrı sürecin tamamını SIGSEGV ile düşürür).
        import threading
        import time

        state = {"cur": 0, "peak": 0}
        guard = threading.Lock()

        class FakePredictor:
            def ocr(self, img, cls=True):
                with guard:
                    state["cur"] += 1
                    state["peak"] = max(state["peak"], state["cur"])
                time.sleep(0.05)
                with guard:
                    state["cur"] -= 1
                return [[]]

        engine = PaddleOcrEngine(
            config=OcrConfig(preprocess=False, upscale_min_side=0), predictor=FakePredictor()
        )
        png = _png_bytes(64, 64)
        threads = [threading.Thread(target=lambda: engine.extract_text(png)) for _ in range(4)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(state["peak"], 1)


if __name__ == "__main__":
    unittest.main()
