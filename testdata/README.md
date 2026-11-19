# testdata — Go / Python / Dart ortak altın vektörler

Aynı mantığın üç dildeki kopyaları (Go `services/expense`, Python `services/ocr`, Dart `fissio_mobile`) bu
dosyalardaki vektörlerle sınanır; bir kopya sürüklenirse test kırılır. Vektör eklerken yalnızca burayı
düzenleyin, üç test paketi de okur.

| Dosya | Mantık | Okuyanlar |
|---|---|---|
| `glyphs.json` | `fixTurkishGlyphs` (`$`→Ş) | Go `accuracy_test.go`, Python `tests/test_preprocess.py`, Dart `test/receipt_parser_test.dart` |
| `rows.json` | satır birleştirme (blok → satır, eğim düzeltmeli) | Python `tests/test_preprocess.py`, Dart `test/on_device_rows_test.dart` |
| `merge.json` | `mergePageTexts` (sayfa dikişi) | Go `merge_golden_test.go`, Dart `test/merge_pages_test.dart` |
| `recurring_due.json` | tekrarlayan gider vadesi + gecikmiş | Go `recurring_due_golden_test.go`, Dart `test/recurring_logic_test.dart` |
| `recurring_series.json` | tekrarlayan seri penceresi/bitişi/gecikmiş | Go `recurring_series_golden_test.go`, Dart `test/recurring_series_golden_test.dart` |
| `parse/*.json` | fiş ayrıştırma (işletme, tutar, tarih, kalemler, `needs_review`, `discount_total`); beklenenler Go `Parse` çıktısıdır (üretim seed kategorileriyle) | Go `golden_parse_test.go`, Dart `test/golden_parse_test.dart` |
| `merchant_brands.json` | başlıkta işletme satırı seçen marka listesi (Go sözlüğünün `brands` birleşimi = Dart `receipt_parser/brands.dart`) | Go `golden_parse_test.go`, Dart `test/golden_parse_test.dart` |

## Yol çözümü
- Go (`services/expense`): `../../testdata`
- Dart (`fissio_mobile`, `flutter test` çalışma dizini): `../testdata`
- Python: `FISSIO_TESTDATA` ortam değişkeni, yoksa depo içi `../../../testdata`, yoksa `/testdata`
  (imajda: `docker run --rm -v "<repo>/services/ocr:/app" -v "<repo>/testdata:/testdata" -w /app fissio-ocr:latest python -m pytest tests/ -q -p no:cacheprovider`)

Bilinen ve kabul edilmiş sapmalar `"known_divergence": ["dart"]` gibi etiketlenir; ilgili dilin testi o vektörü
atlar ve nedenini `"note"` alanında taşır. `parse/*.json` vektörlerinde atlama alan bazındadır: `"skip": ["items", …]`
listesindeki alanlar yalnızca o dilde doğrulanmaz (geri kalanı yine doğrulanır).
