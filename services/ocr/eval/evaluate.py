"""
OCR kalite değerlendirme düzeneği (üretim imajına GİRMEZ; bind mount ile çalıştırılır):

  docker compose run --rm --no-deps -v "$PWD/services/ocr:/app" ocr \
      python eval/evaluate.py --det-limit 960,1600 --preprocess off,both

Her deney kolu (argümanların kartezyen çarpımı) için yeni bir PaddleOcrEngine kurulur,
eval/receipts/*.jpg fotoğrafları okunur ve eval/ground_truth.json ile karşılaştırılır.
`--parse` ile OCR metni ayrıca expense /receipts/parse'a (JWT'li) gönderilir.
"""
from __future__ import annotations

import argparse
import dataclasses
import difflib
import itertools
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent))

from ocr.config import OcrConfig  # noqa: E402
from ocr.paddle_engine import PaddleOcrEngine  # noqa: E402

AMOUNT_RE = re.compile(r"(?:\d{1,3}(?:\.\d{3})+|\d+)[.,]\d{2}\b")
QTY_RE = re.compile(r"^\s*\d+\s*(?:adt|ad|ag|x)?\s*x\s*\d+[.,]\d{2}", re.I)
LABEL_WORDS = ("toplam", "kdv", "nakit", "para", "kart", "tutar", "tarih", "saat", "fis no", "top ")
TR = str.maketrans("İIıÇçĞğÖöŞşÜü", "iiiccggoossuu")


def fold(s: str) -> str:
    return s.translate(TR).lower().strip()


def to_amount(tok: str) -> float:
    ip, fp = tok[:-3], tok[-2:]
    return float(ip.replace(".", "").replace(",", "") + "." + fp)


def amounts_in(line: str) -> list[float]:
    # tarih parçaları tutar sanılmasın
    masked = re.sub(r"\b\d{1,2}[./-]\d{1,2}[./-](?:\d{4}|\d{2})\b", " ", line)
    return [to_amount(m) for m in AMOUNT_RE.findall(masked)]


def clean_name(line: str) -> str:
    cut = [m.start() for m in AMOUNT_RE.finditer(line)]
    name = line[: cut[-1]] if cut else line
    name = re.sub(r"[\s*%]*\d{0,2}\s*$", "", name.strip().rstrip("*"))
    return re.sub(r"%\s*\d{1,2}", " ", name).strip(" *-=_#:")


def extract_items(raw_text: str) -> list[tuple[str, float]]:
    items = []
    for line in raw_text.splitlines():
        f = fold(line)
        if QTY_RE.match(line) or any(w in f for w in LABEL_WORDS):
            continue
        am = amounts_in(line)
        if am:
            items.append((clean_name(line), am[-1]))
    return items


def match_items(found, truth, mode):
    """Multiset eşleşme: her doğru kalem en fazla bir kez eşleşir."""
    used = [False] * len(found)
    hit = 0
    for t in truth:
        for i, (name, amount) in enumerate(found):
            if used[i] or abs(amount - t["amount"]) > 0.005:
                continue
            if mode == "pair" and difflib.SequenceMatcher(None, fold(name), fold(t["name"])).ratio() < 0.6:
                continue
            used[i] = True
            hit += 1
            break
    return hit, len(found) - sum(used)  # (bulunan doğru, fazladan/yanlış)


def date_found(raw_text: str, iso: str) -> bool:
    y, m, d = iso.split("-")
    pats = [f"{d}.{m}.{y}", f"{d}/{m}/{y}", f"{d}-{m}-{y}"]
    return any(p in raw_text.replace(" ", "") for p in pats)


def label_line(raw_text: str, label: str) -> str | None:
    """Etiketi içeren ilk satır. 'TOP'/'TOPLAM' etiketleri TOPKDV satırıyla karışmaz."""
    key = fold(label)
    for line in raw_text.splitlines():
        f = fold(line)
        if key in ("top", "toplam"):
            if "kdv" in f or "topk" in f:
                continue
            if re.search(r"\btop(lam|lan|1am)?\b", f):
                return line
        elif key in f:
            return line
    return None


def critical_score(raw_text: str, critical: list[dict]) -> tuple[int, int]:
    """Etiket doğru satırda doğru tutarla mı (sütun kayması ölçüsü)."""
    ok = 0
    for c in critical:
        line = label_line(raw_text, c["label"])
        if line and any(abs(a - c["amount"]) < 0.005 for a in amounts_in(line)):
            ok += 1
    return ok, len(critical)


def total_found(raw_text: str, total: float) -> bool:
    """Toplam, TOPLAM/TOP etiketli satırda mı bulundu (sıkı ölçü)."""
    line = label_line(raw_text, "toplam")
    return bool(line) and any(abs(a - total) < 0.005 for a in amounts_in(line))


def merchant_score(raw_text: str, merchant: str) -> float:
    lines = [fold(l) for l in raw_text.splitlines()[:6]]
    return max((difflib.SequenceMatcher(None, fold(merchant), l).ratio() for l in lines), default=0.0)


def http_json(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def parse_with_backend(text: str, token: str) -> dict:
    body = json.dumps({"text": text}).encode()
    return http_json(
        "http://expense:8080/receipts/parse",
        body,
        {"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )


def backend_token() -> str:
    email, pw = os.getenv("EVAL_EMAIL"), os.getenv("EVAL_PASSWORD")
    if not email or not pw:
        sys.exit("--parse için EVAL_EMAIL ve EVAL_PASSWORD ortam değişkenleri gerekli")
    body = json.dumps({"email": email, "password": pw}).encode()
    return http_json("http://auth:8080/auth/login", body, {"Content-Type": "application/json"})["token"]


def csv(s: str) -> list[str]:
    return [x.strip() for x in s.split(",") if x.strip()]


def build_arms(a) -> list[dict]:
    arms = []
    for lim, ltype, pre, dd, up in itertools.product(
        csv(a.det_limit), csv(a.det_limit_type), csv(a.preprocess), csv(a.dedupe), csv(a.upscale)
    ):
        arms.append(
            {
                "det_limit_side_len": int(lim),
                "det_limit_type": ltype,
                "preprocess": pre != "off",
                "preprocess_warp": pre in ("warp", "both"),
                "preprocess_clahe": pre in ("clahe", "both"),
                "dedupe": dd == "on",
                "upscale_min_side": int(up),
            }
        )
    return arms


def arm_label(o: dict) -> str:
    pre = "off" if not o["preprocess"] else ("both" if o["preprocess_warp"] and o["preprocess_clahe"] else "warp" if o["preprocess_warp"] else "clahe")
    return f"det{o['det_limit_side_len']}/{o['det_limit_type']} pre={pre} dedupe={'on' if o['dedupe'] else 'off'} up={o['upscale_min_side']}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--det-limit", default="1600")
    ap.add_argument("--det-limit-type", default="max")
    ap.add_argument("--preprocess", default="warp", help="off,warp,clahe,both")
    ap.add_argument("--dedupe", default="on")
    ap.add_argument("--upscale", default="0")
    ap.add_argument("--det-model-dir", default=None)
    ap.add_argument("--rec-model-dir", default=None)
    ap.add_argument("--parse", action="store_true", help="expense /receipts/parse sonucunu da değerlendir")
    ap.add_argument("--show-text", action="store_true", help="OCR metnini yazdır")
    ap.add_argument("--receipts", default="")
    args = ap.parse_args()

    truth = json.loads((ROOT / "ground_truth.json").read_text(encoding="utf-8"))
    files = sorted(p for p in (ROOT / "receipts").glob("*.jpg") if not args.receipts or p.name in csv(args.receipts))
    token = backend_token() if args.parse else None
    base_cfg = OcrConfig.from_env()
    from PIL import Image

    for over in build_arms(args):
        extra = {}
        if args.det_model_dir:
            extra["det_model_dir"] = args.det_model_dir
        if args.rec_model_dir:
            extra["rec_model_dir"] = args.rec_model_dir
        cfg = dataclasses.replace(base_cfg, **over, **extra)
        engine = PaddleOcrEngine(config=cfg)
        print(f"\n=== {arm_label(over)}")
        tot_items_hit = tot_items = 0
        score_total = score_date = crit_sum = crit_all = 0
        for path in files:
            gt = truth[path.name]
            raw = path.read_bytes()
            w, h = Image.open(path).size
            t0 = time.perf_counter()
            res = engine.extract_text(raw)
            ms = (time.perf_counter() - t0) * 1000
            text = res.raw_text
            found = extract_items(text)
            hit, extra_n = match_items(found, gt["items"], gt["items_match"])
            # Kırpık fotoğraflarda toplam/tarih/işletme görünmeyebilir (None): o ölçü sayılmaz (OK varsayılır).
            tot_ok = gt["total"] is None or total_found(text, gt["total"])
            date_ok = gt["date"] is None or date_found(text, gt["date"])
            crit_ok, crit_n = critical_score(text, gt.get("critical", []))
            ms_score = merchant_score(text, gt["merchant"]) if gt["merchant"] else 1.0
            sum_found = round(sum(a for _, a in found), 2)
            scale = min(1.0, cfg.det_limit_side_len / max(w, h)) if cfg.det_limit_type == "max" else 1.0
            line = (
                f"{path.name:16} in={w}x{h} scale~{scale:.2f} | total={'OK' if tot_ok else '--'} "
                f"date={'OK' if date_ok else '--'} merchant={ms_score:.2f} crit={crit_ok}/{crit_n} | "
                f"items {hit}/{len(gt['items'])} (+{extra_n} extra) sum={sum_found} | {ms:.0f}ms"
            )
            if token:
                p = parse_with_backend(text, token)
                line += (
                    f" || parse: amount={p.get('amount')} date={p.get('date')} "
                    f"merchant={p.get('merchant')!r} items={len(p.get('items') or [])} review={p.get('needs_review')}"
                )
            print(line)
            if args.show_text:
                print("  " + text.replace("\n", "\n  "))
            tot_items_hit += hit
            tot_items += len(gt["items"])
            crit_sum += crit_ok
            crit_all += crit_n
            score_total += tot_ok
            score_date += date_ok
        print(f"--- ÖZET: total {score_total}/{len(files)}, date {score_date}/{len(files)}, critical {crit_sum}/{crit_all}, item recall {tot_items_hit}/{tot_items}")


if __name__ == "__main__":
    main()
