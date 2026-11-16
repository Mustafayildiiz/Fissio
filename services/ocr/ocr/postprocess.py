from __future__ import annotations

import difflib
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
