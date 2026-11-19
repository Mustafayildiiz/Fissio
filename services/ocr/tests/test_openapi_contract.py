"""Sözleşme: FastAPI'nin gerçek rota tablosu ile docs/openapi.yaml birbirinden sapamaz (Go servislerindeki
`TestRoutesMatchOpenAPISpec` ile aynı fikir; YAML kütüphanesi gerektirmeyen basit okuyucu)."""
from __future__ import annotations

import os
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def _spec_text() -> str:
    parents = Path(__file__).resolve().parents
    candidates = [os.environ.get("FISSIO_OPENAPI")]
    if len(parents) > 3:
        candidates.append(str(parents[3] / "docs" / "openapi.yaml"))
    candidates.append("/docs/openapi.yaml")
    for c in candidates:
        if c and Path(c).is_file():
            return Path(c).read_text(encoding="utf-8")
    raise unittest.SkipTest("docs/openapi.yaml bulunamadı (FISSIO_OPENAPI ya da /docs bağlayın)")


def _spec_routes(text: str) -> set[str]:
    out: set[str] = set()
    in_paths, cur = False, ""
    for line in text.replace("\r\n", "\n").split("\n"):
        if line.startswith("paths:"):
            in_paths = True
            continue
        if in_paths and line and not line.startswith(" ") and not line.startswith("#"):
            in_paths = False
        if not in_paths:
            continue
        m = re.match(r"^  (/[^\s:]*):\s*$", line)
        if m:
            cur = m.group(1)
            continue
        m = re.match(r"^    (get|post|put|delete|patch):\s*$", line)
        if m and cur:
            out.add(f"{m.group(1).upper()} {cur}")
    return out


class OpenApiContractTests(unittest.TestCase):
    def test_ocr_routes_match_spec(self) -> None:
        import app as ocr_app

        spec = _spec_routes(_spec_text())
        self.assertGreater(len(spec), 10)
        actual: set[str] = set()
        for path, item in ocr_app.app.openapi()["paths"].items():
            for method in item:
                actual.add(f"{method.upper()} {path}")
        missing_in_spec = sorted(actual - spec)
        self.assertEqual(missing_in_spec, [], f"koda olup docs/openapi.yaml'da olmayan OCR rotaları: {missing_in_spec}")
        ocr_spec = {k for k in spec if k.split(" ", 1)[1].startswith("/ocr/") or k == "GET /health"}
        missing_in_code = sorted(ocr_spec - actual)
        self.assertEqual(missing_in_code, [], f"spec'te olup OCR servisinde olmayan rotalar: {missing_in_code}")


if __name__ == "__main__":
    unittest.main()
