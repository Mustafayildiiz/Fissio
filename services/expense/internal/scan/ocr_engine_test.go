package scan

import (
	"encoding/json"
	"testing"
)

// Go fabrikasi, Python OCR servisinin kayit defterindeki (ocr/factory.py) tum takma adlari kabul etmeli:
// mobil istemci "Sunucu OCR motoru" secimini bu adlarla gonderebilir.
func TestOcrEngineFactoryAcceptsEveryPythonAlias(t *testing.T) {
	f := NewOcrEngineFactory("", "http://ocr:8080")
	canonical := map[string][]string{
		"paddleocr": {"paddleocr", "paddle", "ppocr", "pp-ocrv4", "pp-ocrv4-mobile", " PaddleOCR "},
		"custom":    {"custom", "custom_ocr", "inhouse", "fissio_custom"},
	}
	for want, names := range canonical {
		for _, n := range names {
			eng, err := f.Resolve(n)
			if err != nil || eng.Name() != want {
				t.Errorf("Resolve(%q) = %v, %v; want %s", n, eng, err, want)
			}
		}
	}
	if _, err := f.Resolve("bilinmeyen"); err == nil {
		t.Error("bilinmeyen motor reddedilmeli")
	}
}

func TestOcrResultKeepsEngineMetadata(t *testing.T) {
	var r OcrExtractionResult
	raw := `{"raw_text":"x","blocks":[],"confidence":0.9,"engine":"paddleocr","model_version":"v","elapsed_ms":1,"is_empty":false,"metadata":{"rec_model":"latin_PP-OCRv3_rec","missing_letters":["ş"]}}`
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		t.Fatal(err)
	}
	if r.Metadata["rec_model"] != "latin_PP-OCRv3_rec" {
		t.Fatalf("metadata = %v", r.Metadata)
	}
	out, _ := json.Marshal(r)
	var back map[string]any
	_ = json.Unmarshal(out, &back)
	if back["metadata"] == nil {
		t.Fatalf("metadata istemciye tasinmali: %s", out)
	}
}

func TestOcrEngineFactoryResolution(t *testing.T) {
	f := NewOcrEngineFactory("paddleocr", "http://ocr:8080")
	eng, err := f.Resolve("")
	if err != nil || eng.Name() != "paddleocr" {
		t.Fatalf("default resolve = %v, %v", eng, err)
	}
	engAlias, err := f.Resolve("pp-ocrv4")
	if err != nil || engAlias.Name() != "paddleocr" {
		t.Fatalf("alias resolve = %v, %v", engAlias, err)
	}
	customEng, err := f.Resolve("custom")
	if err != nil || customEng.Name() != "custom" {
		t.Fatalf("custom resolve = %v, %v", customEng, err)
	}
	if _, err := f.Resolve("unknown_engine"); err == nil {
		t.Fatal("expected error for unknown engine")
	}
}
