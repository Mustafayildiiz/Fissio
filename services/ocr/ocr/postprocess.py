from __future__ import annotations

import difflib
import statistics
import unicodedata

from .base import OcrTextBlock

_TR_FOLD = str.maketrans("İIıÇçĞğÖöŞşÜü", "iiiccggoossuu")


def _fold(text: str) -> str:
    folded = text.translate(_TR_FOLD).lower()
    return "".join(
        c for c in unicodedata.normalize("NFKD", folded) if not unicodedata.combining(c)
    ).strip()


def _extent(block: OcrTextBlock) -> tuple[float, float, float, float] | None:
    if not block.bbox:
        return None
    xs = [p[0] for p in block.bbox]
    ys = [p[1] for p in block.bbox]
    return min(xs), max(xs), min(ys), max(ys)


def _overlap_ratio(a_min: float, a_max: float, b_min: float, b_max: float) -> float:
    """Kesişimin kısa olan aralığa oranı (0..1)."""
    inter = min(a_max, b_max) - max(a_min, b_min)
    if inter <= 0:
        return 0.0
    shorter = min(a_max - a_min, b_max - b_min)
    return inter / shorter if shorter > 0 else 0.0


def dedupe_blocks(
    blocks: list[OcrTextBlock],
    *,
    y_overlap: float = 0.6,
    x_overlap: float = 0.5,
    text_similarity: float = 0.85,
) -> list[OcrTextBlock]:
    """
    Aynı dikey hizada üst üste binen ve metni benzer olan mükerrer tespitleri tekilleştirir;
    yüksek güvenli olan korunur. Farklı satırlardaki (farklı Y) aynı metinli kalemlere dokunmaz.
    bbox'ı olmayan bloklar olduğu gibi bırakılır. Girdi sırası korunur.
    """
    kept: list[OcrTextBlock] = []
    for block in blocks:
        ext = _extent(block)
        if ext is None:
            kept.append(block)
            continue
        dup_index = None
        for i, other in enumerate(kept):
            oext = _extent(other)
            if oext is None:
                continue
            if _overlap_ratio(ext[2], ext[3], oext[2], oext[3]) < y_overlap:
                continue
            if _overlap_ratio(ext[0], ext[1], oext[0], oext[1]) < x_overlap:
                continue
            ratio = difflib.SequenceMatcher(None, _fold(block.text), _fold(other.text)).ratio()
            if ratio >= text_similarity:
                dup_index = i
                break
        if dup_index is None:
            kept.append(block)
        elif block.confidence > kept[dup_index].confidence:
            kept[dup_index] = block
    return kept


def local_slope_fn(blocks: list[OcrTextBlock], *, max_slope: float = 0.3, neighbors: int = 7):
    """
    Dikey konuma göre değişen satır eğimi s(y) döndürür. Kağıt kıvrık/perspektifli olduğunda
    eğim sayfa boyunca değişir; her konum için en yakın `neighbors` uzun kutunun (genişlik >=
    2 x yükseklik) üst kenar eğiminin ortancası kullanılır. Yeterli kutu yoksa 0 döner.
    Böylece sol etiket ile sağ tutar (aynı satırda ama farklı Y'de görünen) doğru eşleşir.
    """
    samples: list[tuple[float, float]] = []  # (y_center, slope)
    for b in blocks:
        if not b.bbox or len(b.bbox) < 4:
            continue
        (x0, y0), (x1, y1) = b.bbox[0], b.bbox[1]
        ys = [p[1] for p in b.bbox]
        height = max(1.0, max(ys) - min(ys))
        if abs(x1 - x0) < 2 * height:
            continue
        samples.append(((min(ys) + max(ys)) / 2.0, (y1 - y0) / (x1 - x0)))
    if len(samples) < 3:
        return lambda y: 0.0
    samples.sort()

    def slope_at(y: float) -> float:
        near = sorted(samples, key=lambda t: abs(t[0] - y))[:neighbors]
        v = statistics.median(sl for _, sl in near)
        return max(-max_slope, min(max_slope, v))

    return slope_at
