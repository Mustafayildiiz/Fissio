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
from ocr.paddle_engine import PaddleOcrEngine
from ocr.postprocess import dedupe_blocks, fix_turkish_glyphs, group_receipt_rows, local_slope_fn, refine_slope_fn

if HAS_CV:
    from ocr.preprocess import apply_clahe, preprocess_receipt, upscale_if_small


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

    def test_upscale_if_small(self) -> None:
        small = np.zeros((300, 200, 3), np.uint8)
        big = upscale_if_small(small, 800)
        self.assertEqual(big.shape[:2], (900, 600))  # en fazla 3x
        large = np.zeros((1200, 900, 3), np.uint8)
        self.assertIs(upscale_if_small(large, 800), large)

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

    def test_contained_fragment_after_full_line_is_dropped(self) -> None:
        full = OcrTextBlock("EKMEK 5,00", 0.90, _box(40, 100, 300, 118))
        part = OcrTextBlock("5,00", 0.99, _box(245, 101, 298, 117))
        out = dedupe_blocks([full, part])
        self.assertEqual([b.text for b in out], ["EKMEK 5,00"])

    def test_full_line_absorbs_earlier_fragments(self) -> None:
        name = OcrTextBlock("EKMEK", 0.97, _box(42, 101, 120, 117))
        price = OcrTextBlock("5,00", 0.99, _box(245, 101, 298, 117))
        full = OcrTextBlock("EKMEK 5,00", 0.90, _box(40, 100, 300, 118))
        other = OcrTextBlock("SUT 1L", 0.95, _box(40, 140, 120, 158))
        out = dedupe_blocks([name, price, other, full])
        self.assertEqual([b.text for b in out], ["EKMEK 5,00", "SUT 1L"])

    def test_different_text_inside_box_is_kept(self) -> None:
        # Kutu içinde ama metin alt dize değil (farklı içerik): korunur.
        full = OcrTextBlock("EKMEK 5,00", 0.90, _box(40, 100, 300, 118))
        other = OcrTextBlock("%08", 0.90, _box(200, 101, 235, 117))
        self.assertEqual(len(dedupe_blocks([full, other])), 2)

    def test_same_fragment_on_another_row_is_kept(self) -> None:
        full = OcrTextBlock("EKMEK 5,00", 0.90, _box(40, 100, 300, 118))
        price = OcrTextBlock("5,00", 0.99, _box(245, 140, 298, 158))
        self.assertEqual(len(dedupe_blocks([full, price])), 2)


def load_testdata(name: str):
    """`<repo>/testdata/<name>` (Go ve Dart testleriyle ortak altın vektörler); imajda /testdata bağlanır."""
    import json
    import os

    parents = Path(__file__).resolve().parents
    repo_td = str(parents[3] / "testdata") if len(parents) > 3 else None
    candidates = [os.environ.get("FISSIO_TESTDATA"), repo_td, "/testdata"]
    for base in candidates:
        if base and (Path(base) / name).is_file():
            return json.loads((Path(base) / name).read_text(encoding="utf-8"))
    raise unittest.SkipTest(f"testdata/{name} bulunamadı (FISSIO_TESTDATA ya da /testdata bağlayın)")


class TurkishGlyphTests(unittest.TestCase):
    # testdata/glyphs.json: Go (accuracy_test.go) ve Dart (receipt_parser_test.dart) aynı dosyayı okur.
    def test_vectors(self) -> None:
        cases = load_testdata("glyphs.json")["cases"]
        self.assertGreaterEqual(len(cases), 20)
        for c in cases:
            with self.subTest(raw=c["in"]):
                self.assertEqual(fix_turkish_glyphs(c["in"]), c["out"])
                self.assertEqual(fix_turkish_glyphs(c["out"]), c["out"])  # idempotent


class TiltedRowsTests(unittest.TestCase):
    """Eğik/kıvrık fişte sol etiket ile sağ tutar farklı Y'de görünür; satır birleştirme eğimi telafi etmeli."""

    @staticmethod
    def _tilted_blocks(slope: float = 0.1, rows: int = 8, pitch: float = 40.0):
        blocks = []
        for i in range(rows):
            y = 40.0 + pitch * i
            # Etiket: x 100-300, üst kenar eğimli
            blocks.append(
                OcrTextBlock(
                    f"URUN{i}", 0.95,
                    [(100, y), (300, y + slope * 200), (300, y + slope * 200 + 14), (100, y + 14)],
                )
            )
            # Tutar: x 500-560, etiketin satırının eğim kadar altında (kayma)
            dy = slope * 400
            blocks.append(
                OcrTextBlock(
                    f"{i + 1},00", 0.95,
                    [(500, y + dy), (560, y + dy + slope * 60), (560, y + dy + slope * 60 + 14), (500, y + dy + 14)],
                )
            )
        return blocks

    def test_local_slope_is_estimated(self) -> None:
        slope_at = local_slope_fn(self._tilted_blocks())
        self.assertAlmostEqual(slope_at(200.0), 0.1, delta=0.02)

    def test_label_and_amount_end_up_on_the_same_row(self) -> None:
        text, _ = PaddleOcrEngine._reconstruct_receipt_lines(self._tilted_blocks())
        lines = text.splitlines()
        self.assertEqual(len(lines), 8)
        for i, line in enumerate(lines):
            self.assertEqual(line, f"URUN{i} {i + 1},00")

    def test_no_tilt_is_unchanged(self) -> None:
        text, _ = PaddleOcrEngine._reconstruct_receipt_lines(self._tilted_blocks(slope=0.0))
        self.assertEqual(text.splitlines()[0], "URUN0 1,00")


class RefineSlopeTests(unittest.TestCase):
    """Kıvrık kağıt: kutu üst kenarı eğimi 0.02 gösterir ama gerçek satır eğimi aşağı doğru 0.06'ya çıkar."""

    @staticmethod
    def _curved_blocks() -> list[OcrTextBlock]:
        blocks = []
        n = 12
        for k in range(n):
            s = 0.02 + 0.04 * k / (n - 1)
            base = 100 + 40 * k
            yn, ya = base + s * 250, base + s * 818
            blocks.append(OcrTextBlock(f"{k + 1},00", 0.9, [(800, ya - 10), (836, ya - 10), (836, ya + 10), (800, ya + 10)]))
            blocks.append(OcrTextBlock(f"URUN{k}", 0.9, [(100, yn - 16), (400, yn - 10), (400, yn + 16), (100, yn + 10)]))
        return blocks

    def test_pair_estimate_beats_single_box_slope(self) -> None:
        blocks = self._curved_blocks()
        base = local_slope_fn(blocks)
        refined = refine_slope_fn(blocks, base)
        # Tek kutu eğimi hafife alır; çift ölçümü alt satırlarda gerçek eğime (~0.06) yaklaşır.
        self.assertAlmostEqual(base(560), 0.02, places=3)
        self.assertGreater(refined(560), 0.045)

    def test_refined_rows_pair_every_label_with_its_amount(self) -> None:
        blocks = self._curved_blocks()
        rows = group_receipt_rows(blocks, refine_slope_fn(blocks, local_slope_fn(blocks)))
        self.assertEqual(len(rows), 12)
        for k, row in enumerate(rows):
            self.assertEqual(sorted(e[0].text for e in row), sorted([f"URUN{k}", f"{k + 1},00"]))

    def test_too_few_wide_rows_keeps_the_base_estimate(self) -> None:
        blocks = [OcrTextBlock("A", 0.9, _box(0, 0, 100, 20)), OcrTextBlock("B", 0.9, _box(0, 40, 100, 60))]
        base = local_slope_fn(blocks)
        self.assertIs(refine_slope_fn(blocks, base), base)

    def test_blocks_without_boxes_are_kept_as_a_row(self) -> None:
        blocks = [OcrTextBlock("kutusuz", 0.9, None), OcrTextBlock("X", 0.9, _box(0, 40, 100, 60))]
        rows = group_receipt_rows(blocks, lambda y: 0.0)
        self.assertEqual(sum(len(r) for r in rows), 2)


class SharedRowVectorsTests(unittest.TestCase):
    """testdata/rows.json: Dart `reconstructRows` aynı vektörleri okur (bkz. receipt_parser/on-device testleri)."""

    def test_vectors(self) -> None:
        cases = load_testdata("rows.json")["cases"]
        self.assertGreaterEqual(len(cases), 5)
        for c in cases:
            with self.subTest(case=c["name"]):
                blocks = [OcrTextBlock(b["text"], 0.95, [tuple(p) for p in b["box"]]) for b in c["blocks"]]
                text, _ = PaddleOcrEngine._reconstruct_receipt_lines(blocks)
                self.assertEqual(text.split(chr(10)), c["rows"])


if __name__ == "__main__":
    unittest.main()
