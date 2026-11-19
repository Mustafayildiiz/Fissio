package main

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"fissio/expense/internal/scan"
)

// /receipts/scan isleyicisinin HTTP sozlesmesi (429, 502 ocr_unavailable); OCR orkestrasyonu testleri
// internal/scan'dadir.

// failingOcr her sayfada ayni hatayi donduren OcrEngine'dir.
type failingOcr struct{ err error }

func (failingOcr) Name() string { return "fake" }
func (f failingOcr) ExtractText(context.Context, []byte) (*scan.OcrExtractionResult, error) {
	return nil, f.err
}

func TestScanHandlerAnswersTooManyScans(t *testing.T) {
	lim := scan.NewLimiter(1, 100)
	rel, _, _ := lim.Acquire(0, time.Now()) // userID verilmedi => 0
	defer rel()
	w := postFiles(t, "/receipts/scan", (&handler{scanLim: lim}).scanReceipt, 10)
	if w.Code != 429 || w.Header().Get("Retry-After") == "" || !strings.Contains(w.Body.String(), "scan_busy") {
		t.Fatalf("code=%d retry=%q body=%s", w.Code, w.Header().Get("Retry-After"), w.Body.String())
	}
}

func TestScanHandlerAllPagesFailedLeaksNoInternals(t *testing.T) {
	f := scan.NewOcrEngineFactory("fake", "")
	f.Register("fake", failingOcr{errors.New("ocr engine returned status 500: dial tcp 172.19.0.3:8080 secret")})
	w := postFiles(t, "/receipts/scan", (&handler{ocrFactory: f, scanLim: scan.NewLimiter(2, 10)}).scanReceipt, 10, 10)
	if w.Code != 502 || !strings.Contains(w.Body.String(), "ocr_unavailable") {
		t.Fatalf("code=%d body=%s", w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), "172.19") || strings.Contains(w.Body.String(), "secret") {
		t.Fatalf("ic ayrinti sizdi: %s", w.Body.String())
	}
}
