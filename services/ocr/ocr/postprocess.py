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


# `$` ile yazılan döviz kodları (US$ 1,00); tek harfli kodlar (A$) "A.$" şirket sonekiyle karışır.
_CURRENCY_PREFIXES = frozenset({"US", "CA", "AU", "NZ", "HK", "SG"})


def fix_turkish_glyphs(text: str) -> str:
    """
    OCR'ın Türkçe harf yerine okuduğu `$` glifini bağlama göre `Ş`/`ş`'ye çevirir.

    Kök neden: PaddleOCR `lang=tr` isteğini `latin` tanıma modeline yönlendirir; bu modelin
    karakter sözlüğünde (latin_dict.txt) ş/Ş, ğ/Ğ ve İ YOKTUR, `$` ise vardır. Model sözlükte
    olmayan harfi en yakın glife eşler (FİŞ -> Fİ$, PEŞİN -> PE$İN). Kurallar expense servisindeki
    `fixTurkishGlyphs` ile birebir aynıdır:
      - `$` hemen ardından rakam geliyorsa fiyat işaretidir, dokunulmaz ($12,50, *$070).
      - Aksi halde yanlarından en az biri harfse `Ş` (komşu harf küçükse `ş`).
      - Şirket soneki: tek harf + nokta + `$` (A.$.) -> A.Ş.
      - Para birimi: `$`'dan önceki harf dizisi bir döviz kodu (US$, CA$...) ve ardından harf
        gelmiyorsa dokunulmaz.
    İdempotenttir.
    """
    if "$" not in text:
        return text
    chars = list(text)

    def at(i: int) -> str:
        return chars[i] if 0 <= i < len(chars) else ""

    for i, c in enumerate(chars):
        if c != "$":
            continue
        prev, nxt = at(i - 1), at(i + 1)
        if nxt.isdigit():
            continue
        if not nxt.isalpha():
            start = i
            while start > 0 and chars[start - 1].isalpha():
                start -= 1
            if "".join(chars[start:i]).upper() in _CURRENCY_PREFIXES:
                continue
        if nxt.isalpha():
            ref = nxt
        elif prev.isalpha():
            ref = prev
        elif prev == "." and at(i - 2).isalpha() and not at(i - 3).isalpha():
            ref = at(i - 2)
        else:
            continue
        chars[i] = "ş" if ref.islower() else "Ş"
    return "".join(chars)


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


def _area(ext: tuple[float, float, float, float]) -> float:
    return max(0.0, ext[1] - ext[0]) * max(0.0, ext[3] - ext[2])


def _intersection(
    a: tuple[float, float, float, float], b: tuple[float, float, float, float]
) -> float:
    w = min(a[1], b[1]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[2], b[2])
    return w * h if w > 0 and h > 0 else 0.0


def _compact(text: str) -> str:
    return _fold(text).replace(" ", "")


def _is_contained_duplicate(
    small: OcrTextBlock,
    s_ext: tuple[float, float, float, float],
    big: OcrTextBlock,
    b_ext: tuple[float, float, float, float],
    min_inside: float,
) -> bool:
    """
    Kısa blok, uzun bloğun parçasının ikinci kez tespit edilmiş hali mi? Kutusu büyük ölçüde
    (kesişim / kendi alanı >= min_inside) uzun kutunun içinde VE katlanmış metni uzun metnin
    alt dizesi olmalı ("5,00" ⊂ "EKMEK 5,00"). İçerdeki farklı metin (alt dize değil) korunur.
    """
    st, bt = _compact(small.text), _compact(big.text)
    if not st or len(st) >= len(bt) or st not in bt:
        return False
    area = _area(s_ext)
    return area > 0 and _intersection(s_ext, b_ext) / area >= min_inside


def dedupe_blocks(
    blocks: list[OcrTextBlock],
    *,
    y_overlap: float = 0.6,
    x_overlap: float = 0.5,
    text_similarity: float = 0.85,
    containment: float = 0.8,
) -> list[OcrTextBlock]:
    """
    Tek görseldeki mükerrer tespitleri NMS mantığıyla tekilleştirir:

    1. Aynı hizada üst üste binen (her eksende kısa aralığa göre örtüşme: IoMin; IoU'dan daha
       kapsayıcı, küçük kaymalı çift kutuları da yakalar) ve metni benzer kutulardan yüksek
       güvenli olan korunur.
    2. Bir kutunun içine düşen ve metni o kutunun alt dizesi olan parça tespitler ("5,00" ve
       "EKMEK 5,00") atılır; tam metinli kutu korunur. Aksi halde satır "EKMEK 5,00 5,00" olur.

    Farklı satırlardaki (farklı Y) aynı metinli kalemlere dokunmaz. bbox'ı olmayan bloklar olduğu
    gibi bırakılır. Girdi sırası korunur.
    """
    kept: list[OcrTextBlock] = []
    for block in blocks:
        ext = _extent(block)
        if ext is None:
            kept.append(block)
            continue
        dup_index = None
        inside_existing = False
        for i, other in enumerate(kept):
            oext = _extent(other)
            if oext is None:
                continue
            if _is_contained_duplicate(block, ext, other, oext, containment):
                inside_existing = True
                break
            if _overlap_ratio(ext[2], ext[3], oext[2], oext[3]) < y_overlap:
                continue
            if _overlap_ratio(ext[0], ext[1], oext[0], oext[1]) < x_overlap:
                continue
            ratio = difflib.SequenceMatcher(None, _fold(block.text), _fold(other.text)).ratio()
            if ratio >= text_similarity:
                dup_index = i
                break
        if inside_existing:
            continue
        if dup_index is not None:
            if block.confidence > kept[dup_index].confidence:
                kept[dup_index] = block
            continue
        # Yeni blok, daha önce tutulmuş parça tespitleri kapsıyorsa onların yerini alır.
        absorbed = [
            i
            for i, other in enumerate(kept)
            if (oext := _extent(other)) is not None
            and _is_contained_duplicate(other, oext, block, ext, containment)
        ]
        if absorbed:
            kept[absorbed[0]] = block
            for i in reversed(absorbed[1:]):
                del kept[i]
        else:
            kept.append(block)
    return kept


def local_slope_fn(
    blocks: list[OcrTextBlock],
    *,
    max_slope: float = 0.3,
    neighbors: int = 7,
    min_aspect: float = 2.0,
):
    """
    Dikey konuma göre değişen satır eğimi s(y) döndürür. Kağıt kıvrık/perspektifli olduğunda
    eğim sayfa boyunca değişir; her konum için en yakın `neighbors` uzun kutunun (genişlik >=
    `min_aspect` x yükseklik) üst kenar eğiminin ortancası kullanılır. Yeterli kutu yoksa 0 döner.
    Böylece sol etiket ile sağ tutar (aynı satırda ama farklı Y'de görünen) doğru eşleşir.

    Tek kutunun üst kenar eğimi yalnızca kısa bir tabana dayanır ve kıvrık/perspektifli kağıtta
    sayfa boyunca gerçek satır eğimini hafife alabilir; bu yüzden sonuç `refine_slope_fn` ile
    satır ÇİFTLERİNDEN (sol ad - sağ tutar) yeniden kestirilir.
    """
    samples: list[tuple[float, float]] = []  # (y_center, slope)
    for b in blocks:
        if not b.bbox or len(b.bbox) < 4:
            continue
        (x0, y0), (x1, y1) = b.bbox[0], b.bbox[1]
        ys = [p[1] for p in b.bbox]
        height = max(1.0, max(ys) - min(ys))
        if abs(x1 - x0) < min_aspect * height:
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


# Satır grubu girdisi: (blok, eğim düzeltmeli y, x_min, yükseklik, x_merkez, ham y_merkez).
RowEntry = tuple[OcrTextBlock, float, float, float, float, float]


def group_receipt_rows(blocks: list[OcrTextBlock], slope_at) -> list[list[RowEntry]]:
    """
    Bloklari fis satirlarina gruplar: y_adj = y - s(y) * x ile eğim düzeltilir, (y_adj, x_min) sırasına
    dizilir ve satır ortalama y'sine yeterince yakın bloklar aynı satıra eklenir.
    """
    annotated: list[RowEntry] = []
    for b in blocks:
        if not b.bbox:
            annotated.append((b, 0.0, 0.0, 20.0, 0.0, 0.0))  # bbox'sız blok: üstte, ortalama yükseklikte
            continue
        xs = [pt[0] for pt in b.bbox]
        ys = [pt[1] for pt in b.bbox]
        y_raw = (min(ys) + max(ys)) / 2.0
        x_center = (min(xs) + max(xs)) / 2.0
        annotated.append(
            (b, y_raw - slope_at(y_raw) * x_center, min(xs), max(1.0, max(ys) - min(ys)), x_center, y_raw)
        )
    annotated.sort(key=lambda e: (e[1], e[2]))

    rows: list[list[RowEntry]] = []
    for entry in annotated:
        if not rows:
            rows.append([entry])
            continue
        current = rows[-1]
        avg_y = sum(e[1] for e in current) / len(current)
        avg_h = sum(e[3] for e in current) / len(current)
        if abs(entry[1] - avg_y) <= max(8.0, avg_h * 0.55):
            current.append(entry)
        else:
            rows.append([entry])
    return rows


def refine_slope_fn(
    blocks: list[OcrTextBlock],
    base_fn,
    *,
    iterations: int = 2,
    neighbors: int = 7,
    max_slope: float = 0.3,
    min_span: float = 8.0,
):
    """
    Satır eğimini satır ÇİFTLERİNDEN yeniden kestirir. Kıvrık/perspektifli fişte tek kutunun üst kenar
    eğimi (kısa taban) gerçek satır eğimini hafife alır; sağ sütun (tutar) bir satır kayar. Burada
    mevcut kestirimle satırlar kurulur, geniş (>= `min_span` x yükseklik) satırların en sol ve en sağ
    blok merkezlerinden gerçek eğim ölçülür ve konuma göre en yakın `neighbors` ölçümün ortancası alınır.
    Birkaç yinelemeyle başlangıç hatası kapanır. Yeterli (>= 3) geniş satır yoksa `base_fn` aynen döner.
    """
    fn = base_fn
    for _ in range(iterations):
        samples: list[tuple[float, float]] = []
        for row in group_receipt_rows(blocks, fn):
            if len(row) < 2:
                continue
            ordered = sorted(row, key=lambda e: e[4])
            left, right = ordered[0], ordered[-1]
            height = statistics.median(e[3] for e in row)
            dx = right[4] - left[4]
            if dx < min_span * height:
                continue
            slope = (right[5] - left[5]) / dx
            if abs(slope) <= max_slope:
                samples.append(((left[5] + right[5]) / 2.0, slope))
        if len(samples) < 3:
            break
        samples.sort()

        def make(points: list[tuple[float, float]]):
            def slope_at(y: float) -> float:
                near = sorted(points, key=lambda t: abs(t[0] - y))[:neighbors]
                return statistics.median(sl for _, sl in near)

            return slope_at

        fn = make(samples)
    return fn
