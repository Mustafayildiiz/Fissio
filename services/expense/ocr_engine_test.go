package main

import (
	"fmt"
	"net/http"
	"testing"
)

func strp(s string) *string { return &s }

// ocr_engine: fisi okuyan motor (bilgi amacli). Bos/yok = bilinmiyor, bicim disi deger reddedilir.
func TestValidateOcrEngine(t *testing.T) {
	ok := []struct {
		in   *string
		want string // "" = nil bekleniyor
	}{
		{nil, ""},
		{strp(""), ""},
		{strp("   "), ""},
		{strp("paddleocr"), "paddleocr"},
		{strp(" MLKit "), "mlkit"},
		{strp("custom"), "custom"},
		{strp("my-engine_2"), "my-engine_2"},
	}
	for _, c := range ok {
		in := expenseInput{Amount: 10, Date: "2026-05-12", OcrEngine: c.in}
		if _, msg := in.validate(); msg != "" {
			t.Fatalf("validate(%v): %s", c.in, msg)
		}
		switch {
		case c.want == "" && in.OcrEngine != nil:
			t.Fatalf("%v must normalise to nil, got %q", c.in, *in.OcrEngine)
		case c.want != "" && (in.OcrEngine == nil || *in.OcrEngine != c.want):
			t.Fatalf("%v must normalise to %q, got %v", c.in, c.want, in.OcrEngine)
		}
	}
	for _, bad := range []string{"<script>", "a b", "x;drop", "ünicode", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"} {
		in := expenseInput{Amount: 10, Date: "2026-05-12", OcrEngine: strp(bad)}
		if _, msg := in.validate(); msg != "invalid ocr_engine" {
			t.Fatalf("%q must be rejected, got %q", bad, msg)
		}
	}
	var n *expenseInput = &expenseInput{}
	if n.ocrArg() != nil {
		t.Fatal("nil engine must map to a NULL argument")
	}
	if got := (&expenseInput{OcrEngine: strp("mlkit")}).ocrArg(); got != "mlkit" {
		t.Fatalf("ocrArg = %v", got)
	}
}

// Uctan uca: olusturma/okuma/liste, PUT'ta korunma + degisme, toplu yukleme (offline kuyruk), eski satir null.
func TestPGOcrEngineLifecycle(t *testing.T) {
	e := newXEnv(t)
	const alice = int64(1)

	// Manuel: alan yok -> null.
	manual := e.create(alice, e.exp("Manuel", 10, 0, nil))
	if manual.OcrEngine != nil {
		t.Fatalf("manual receipt must have no engine: %v", *manual.OcrEngine)
	}

	// Taramadan: motor kaydedilir (kucuk harfe normallesir) ve get/list'te gorunur.
	scanned := e.create(alice, e.exp("Tarama", 20, 0, map[string]any{"ocr_engine": "PaddleOCR"}))
	if scanned.OcrEngine == nil || *scanned.OcrEngine != "paddleocr" {
		t.Fatalf("create must store the engine: %v", scanned.OcrEngine)
	}
	path := fmt.Sprintf("/expenses/%d", scanned.ID)
	code, b := e.as(alice, "GET", path, nil)
	e.want(code, http.StatusOK, b, "get")
	if g := decodeExpense(t, b); g.OcrEngine == nil || *g.OcrEngine != "paddleocr" {
		t.Fatalf("get lost the engine: %v", g.OcrEngine)
	}
	listed := map[string]*string{}
	for _, x := range e.list(alice, "") {
		listed[x.Merchant] = x.OcrEngine
	}
	if listed["Tarama"] == nil || *listed["Tarama"] != "paddleocr" || listed["Manuel"] != nil {
		t.Fatalf("list engines: %v", listed)
	}

	// PUT alani atlarsa korunur (duzenleme motoru silmez); null/bos gonderilse de silmez.
	for name, body := range map[string]map[string]any{
		"omitted": e.exp("Tarama", 21, 0, nil),
		"null":    e.exp("Tarama", 22, 0, map[string]any{"ocr_engine": nil}),
		"empty":   e.exp("Tarama", 23, 0, map[string]any{"ocr_engine": ""}),
	} {
		code, b = e.as(alice, "PUT", path, body)
		e.want(code, http.StatusOK, b, "put "+name)
		if g := decodeExpense(t, b); g.OcrEngine == nil || *g.OcrEngine != "paddleocr" {
			t.Fatalf("PUT with %s engine must keep it: %v", name, g.OcrEngine)
		}
	}
	// Degerle PUT degistirir.
	code, b = e.as(alice, "PUT", path, e.exp("Tarama", 24, 0, map[string]any{"ocr_engine": "mlkit"}))
	e.want(code, http.StatusOK, b, "put value")
	if g := decodeExpense(t, b); g.OcrEngine == nil || *g.OcrEngine != "mlkit" {
		t.Fatalf("PUT with a value must replace it: %v", g.OcrEngine)
	}
	// Gecersiz deger 400.
	code, b = e.as(alice, "POST", "/expenses", e.exp("Kotu", 1, 0, map[string]any{"ocr_engine": "<b>"}))
	e.want(code, http.StatusBadRequest, b, "invalid engine")

	// Toplu yukleme (cevrimdisi kuyruk) motoru tasir.
	item := e.exp("Kuyruk", 30, 0, map[string]any{"client_uid": "q-1", "ocr_engine": "mlkit"})
	code, b = e.as(alice, "POST", "/expenses/bulk", map[string]any{"expenses": []any{item}})
	e.want(code, http.StatusOK, b, "bulk")
	var queued expenseOut
	for _, x := range e.list(alice, "") {
		if x.Merchant == "Kuyruk" {
			queued = x
		}
	}
	if queued.OcrEngine == nil || *queued.OcrEngine != "mlkit" {
		t.Fatalf("bulk upload must keep the engine: %v", queued.OcrEngine)
	}

	// Eski satir (kolon NULL): JSON'da null.
	if _, err := e.db.Exec(`UPDATE expense.expenses SET ocr_engine = NULL WHERE id = $1`, queued.ID); err != nil {
		t.Fatal(err)
	}
	code, b = e.as(alice, "GET", fmt.Sprintf("/expenses/%d", queued.ID), nil)
	e.want(code, http.StatusOK, b, "get legacy")
	if g := decodeExpense(t, b); g.OcrEngine != nil {
		t.Fatalf("legacy row must read back as null: %v", *g.OcrEngine)
	}
}
