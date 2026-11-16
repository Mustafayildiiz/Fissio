from __future__ import annotations

from typing import Any

# Perspektif düzeltme için kabul edilen alan oranı (kontur alanı / görsel alanı).
_MIN_AREA_RATIO = 0.20
_MAX_AREA_RATIO = 0.98
# Çıktı en-boy oranı sınırı (aşırı ince/uzun dörtgenler fiş değildir).
_MAX_ASPECT = 8.0
_DETECT_HEIGHT = 500


def _order_points(pts: Any) -> Any:
    """Köşeleri sol-üst, sağ-üst, sağ-alt, sol-alt sırasına dizer."""
    import numpy as np

    pts = np.asarray(pts, dtype="float32").reshape(4, 2)
    s = pts.sum(axis=1)
    d = np.diff(pts, axis=1).ravel()
    return np.array(
        [pts[np.argmin(s)], pts[np.argmin(d)], pts[np.argmax(s)], pts[np.argmax(d)]],
        dtype="float32",
    )


def _find_receipt_quad(img: Any) -> Any | None:
    """Fiş sınırını 4 köşeli bir dışbükey konturla bulur; bulunamazsa None."""
    import cv2
    import numpy as np

    h, w = img.shape[:2]
    scale = _DETECT_HEIGHT / float(h) if h > _DETECT_HEIGHT else 1.0
    if scale != 1.0:
        small = cv2.resize(img, (max(1, int(w * scale)), max(1, int(h * scale))))
    else:
        small = img
    gray = cv2.cvtColor(small, cv2.COLOR_RGB2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(gray, 50, 150)
    edges = cv2.dilate(edges, np.ones((3, 3), np.uint8), iterations=2)

    contours, _ = cv2.findContours(edges, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    total_area = float(small.shape[0] * small.shape[1])
    contour = max(contours, key=cv2.contourArea)
    ratio = cv2.contourArea(contour) / total_area
    if not (_MIN_AREA_RATIO <= ratio <= _MAX_AREA_RATIO):
        return None
    peri = cv2.arcLength(contour, True)
    approx = cv2.approxPolyDP(contour, 0.02 * peri, True)
    if len(approx) != 4 or not cv2.isContourConvex(approx):
        return None
    return _order_points(approx.reshape(4, 2)) / scale


def _warp(img: Any, quad: Any) -> Any:
    import cv2
    import numpy as np

    tl, tr, br, bl = quad
    width = int(round(max(np.linalg.norm(br - bl), np.linalg.norm(tr - tl))))
    height = int(round(max(np.linalg.norm(tr - br), np.linalg.norm(tl - bl))))
    if width < 50 or height < 50:
        return img
    aspect = max(width, height) / float(min(width, height))
    if aspect > _MAX_ASPECT:
        return img
    dst = np.array(
        [[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]], dtype="float32"
    )
    matrix = cv2.getPerspectiveTransform(quad, dst)
    return cv2.warpPerspective(img, matrix, (width, height))


def apply_clahe(img: Any, *, clip_limit: float = 2.0, tile: int = 8) -> Any:
    """LAB'in L kanalına CLAHE uygular; çıktı yine 3 kanallı RGB'dir."""
    import cv2

    lab = cv2.cvtColor(img, cv2.COLOR_RGB2LAB)
    l_chan, a_chan, b_chan = cv2.split(lab)
    clahe = cv2.createCLAHE(clipLimit=clip_limit, tileGridSize=(tile, tile))
    merged = cv2.merge((clahe.apply(l_chan), a_chan, b_chan))
    return cv2.cvtColor(merged, cv2.COLOR_LAB2RGB)


def preprocess_receipt(img: Any, *, enable_warp: bool = True, enable_clahe: bool = True) -> Any:
    """
    Hafif fiş ön işleme: 4 nokta perspektif düzeltme + CLAHE kontrast dengeleme.

    Hiçbir koşulda istisna fırlatmaz; girdi uygun değilse veya bir adım başarısız olursa
    o adım atlanır ve (mümkün olan en iyi) görsel döner. Girdi RGB `np.ndarray (H, W, 3)` olmalıdır.
    """
    try:
        import cv2  # noqa: F401
        import numpy as np
    except ImportError:
        return img

    if not isinstance(img, np.ndarray) or img.ndim != 3 or img.shape[2] != 3 or img.size == 0:
        return img
    if img.dtype != np.uint8:
        return img

    out = img
    if enable_warp:
        try:
            quad = _find_receipt_quad(out)
            if quad is not None:
                out = _warp(out, quad)
        except Exception:
            out = img
    if enable_clahe:
        try:
            out = apply_clahe(out)
        except Exception:
            pass
    return out
