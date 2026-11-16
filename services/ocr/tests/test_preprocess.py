from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import cv2
    import numpy as np

    HAS_CV = True
except ImportError:  # pragma: no cover
    HAS_CV = False

from ocr.base import OcrTextBlock
from ocr.postprocess import dedupe_blocks

if HAS_CV:
    from ocr.preprocess import apply_clahe, preprocess_receipt


def _box(x1: float, y1: float, x2: float, y2: float):
    return [(x1, y1), (x2, y1), (x2, y2), (x1, y2)]


@unittest.skipUnless(HAS_CV, "opencv/numpy not installed")
class PreprocessTests(unittest.TestCase):
    def test_skewed_receipt_on_dark_background_is_warped(self) -> None:
        img = np.full((600, 800, 3), 20, np.uint8)
        quad = np.array([[220, 60], [600, 100], [560, 540], [180, 500]], np.int32)
        cv2.fillConvexPoly(img, quad, (240, 240, 240))
        out = preprocess_receipt(img, enable_clahe=False)
        # Dörtgen ~382x~440 civarı: çıktı orijinalden küçük ve dikdörtgene yakın olmalı.
        self.assertLess(out.shape[1], 600)
        self.assertLess(out.shape[0], 560)
        self.assertGreater(out.shape[0], 380)
        # Düzeltilmiş çıktı neredeyse tamamen beyaz (fiş) olmalı.
        self.assertGreater(float(out.mean()), 200.0)

    def test_text_lines_on_white_canvas_fall_back_to_original(self) -> None:
        # Kenarlıksız beyaz zemin üstünde metin satırları: gerçekçi yanlış pozitif.
        img = np.full((900, 400, 3), 255, np.uint8)
        for i in range(12):
            cv2.putText(img, f"URUN {i} 12,50", (30, 60 + i * 65), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 2)
        out = preprocess_receipt(img, enable_clahe=False)
        self.assertEqual(out.shape, img.shape)

    def test_blank_image_returned_unchanged(self) -> None:
        img = np.full((300, 200, 3), 255, np.uint8)
        out = preprocess_receipt(img, enable_clahe=False)
        self.assertEqual(out.shape, img.shape)
        self.assertTrue(np.array_equal(out, img))

    def test_clahe_raises_contrast_of_low_contrast_image(self) -> None:
        rng = np.random.default_rng(0)
        img = (120 + rng.integers(-8, 8, (200, 200, 3))).astype(np.uint8)
        out = apply_clahe(img)
        self.assertEqual(out.shape, img.shape)
        self.assertGreater(float(out.std()), float(img.std()))

    def test_invalid_inputs_do_not_raise(self) -> None:
        for bad in ([[0, 0, 0]], None, "x", np.zeros((0, 0, 3), np.uint8), np.zeros((10, 10), np.uint8)):
            self.assertIs(preprocess_receipt(bad), bad)
        float_img = np.zeros((10, 10, 3), np.float32)
        self.assertIs(preprocess_receipt(float_img), float_img)


class DedupeTests(unittest.TestCase):
    def test_overlapping_duplicate_detection_keeps_highest_confidence(self) -> None:
        a = OcrTextBlock("SUT 1L TAM YAGLI", 0.90, _box(40, 92, 160, 110))
        b = OcrTextBlock("SUT 1L TAM YAGLI", 0.97, _box(42, 93, 162, 111))
        out = dedupe_blocks([a, b])
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].confidence, 0.97)

    def test_similar_text_with_ocr_noise_is_merged(self) -> None:
        a = OcrTextBlock("EKMEK 500G", 0.94, _box(40, 122, 150, 140))
        b = OcrTextBlock("EKMEK 5O0G", 0.80, _box(41, 123, 151, 141))
        self.assertEqual(len(dedupe_blocks([a, b])), 1)

    def test_same_text_on_different_rows_is_kept(self) -> None:
        a = OcrTextBlock("EKMEK 5,00", 0.95, _box(40, 100, 150, 118))
        b = OcrTextBlock("EKMEK 5,00", 0.95, _box(40, 140, 150, 158))
        self.assertEqual(len(dedupe_blocks([a, b])), 2)

    def test_different_text_same_row_is_kept(self) -> None:
        a = OcrTextBlock("SUT 1L", 0.95, _box(40, 100, 120, 118))
        b = OcrTextBlock("34,50", 0.95, _box(240, 100, 300, 118))
        self.assertEqual(len(dedupe_blocks([a, b])), 2)

    def test_blocks_without_bbox_are_untouched(self) -> None:
        a = OcrTextBlock("TOPLAM", 0.9, None)
        b = OcrTextBlock("TOPLAM", 0.9, None)
        self.assertEqual(len(dedupe_blocks([a, b])), 2)


if __name__ == "__main__":
    unittest.main()
