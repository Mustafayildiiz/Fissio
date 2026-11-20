package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
)

// document_no: YALNIZCA 36 karakterli ETTN UUID'si ya da VKN_FaturaNo kabul edilir; kisa fis/siparis/Z numaralari
// (baska belgelerle cakisirdi) reddedilir. Normalize: ETTN kucuk, fatura no buyuk harf.
func TestValidateDocumentNo(t *testing.T) {
	ok := []struct{ in, want string }{
		{"f47ac10b-58cc-4372-a567-0e02b2c3d479", "f47ac10b-58cc-4372-a567-0e02b2c3d479"},
		{" F47AC10B-58CC-4372-A567-0E02B2C3D479 ", "f47ac10b-58cc-4372-a567-0e02b2c3d479"},
		{"1750051846_abc2021000000123", "1750051846_ABC2021000000123"},
		{"12345678901_GIB2024000000001", "12345678901_GIB2024000000001"},
	}
	for _, c := range ok {
		in := expenseInput{Amount: 10, Date: "2026-05-12", DocumentNo: strp(c.in)}
		if _, msg := in.validate(); msg != "" {
			t.Fatalf("validate(%q): %s", c.in, msg)
		}
		if in.DocumentNo == nil || *in.DocumentNo != c.want {
			t.Fatalf("%q must normalise to %q, got %v", c.in, c.want, in.DocumentNo)
		}
	}
	// Bos/bosluk = belge numarasi yok (nil).
	for _, empty := range []string{"", "   "} {
		in := expenseInput{Amount: 10, Date: "2026-05-12", DocumentNo: strp(empty)}
		if _, msg := in.validate(); msg != "" || in.DocumentNo != nil {
			t.Fatalf("%q must normalise to nil (msg=%q, got %v)", empty, msg, in.DocumentNo)
		}
	}
	// Kisa fis/siparis/Z numaralari ve bicim disi her sey reddedilir.
	for _, bad := range []string{
		"0468", "01D", "FIS NO 0468", "0298", "527212", "15024061",
		"f47ac10b-58cc-4372-a567-0e02b2c3d47",  // 35 karakter
		"f47ac10b58cc4372a5670e02b2c3d479",     // tireler yok
		"g47ac10b-58cc-4372-a567-0e02b2c3d479", // hex degil
		"175005184_ABC2021000000123",           // 9 haneli VKN
		"1750051846_",                          // fatura no yok
		"1750051846_AB",                        // cok kisa fatura no
		"1750051846 ABC2021000000123",          // alt cizgi yok
	} {
		in := expenseInput{Amount: 10, Date: "2026-05-12", DocumentNo: strp(bad)}
		if _, msg := in.validate(); msg != "invalid document_no" {
			t.Fatalf("%q must be rejected, got %q", bad, msg)
		}
	}
	if got := (&expenseInput{}).documentArg(); got != nil {
		t.Fatal("nil document must map to a NULL argument")
	}
}

// Uctan uca: kaydetme/okuma, mukerrer 409, baska hesapta serbest, PUT'ta korunma, toplu yuklemede mukerrer hata.
func TestPGDocumentNoDuplicates(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	const ettn = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

	first := e.create(alice, e.exp("E-Arsiv", 120, 0, map[string]any{"client_uid": "d-1", "document_no": ettn, "ocr_engine": "pdf"}))
	if first.DocumentNo == nil || *first.DocumentNo != ettn {
		t.Fatalf("create must store the document no: %v", first.DocumentNo)
	}
	path := fmt.Sprintf("/expenses/%d", first.ID)
	code, b := e.as(alice, "GET", path, nil)
	e.want(code, http.StatusOK, b, "get")
	if g := decodeExpense(t, b); g.DocumentNo == nil || *g.DocumentNo != ettn {
		t.Fatalf("get lost the document no: %v", g.DocumentNo)
	}

	// Ayni client_uid tekrari idempotent (200, mukerrer sayilmaz).
	code, b = e.as(alice, "POST", "/expenses", e.exp("E-Arsiv", 120, 0, map[string]any{"client_uid": "d-1", "document_no": ettn}))
	e.want(code, http.StatusOK, b, "idempotent repeat")

	// Ayni belge FARKLI client_uid ile: 409 duplicate_document.
	code, b = e.as(alice, "POST", "/expenses", e.exp("E-Arsiv kopya", 120, 0, map[string]any{"client_uid": "d-2", "document_no": ettn}))
	e.want(code, http.StatusConflict, b, "duplicate")
	var er struct{ Code string }
	_ = json.Unmarshal(b, &er)
	if er.Code != "duplicate_document" {
		t.Fatalf("duplicate must answer code duplicate_document: %s", b)
	}

	// Baska hesap ayni belgeyi ekleyebilir (tekillik hesap basina).
	if other := e.create(bob, e.exp("E-Arsiv", 120, 0, map[string]any{"client_uid": "d-1", "document_no": ettn})); other.DocumentNo == nil {
		t.Fatal("another account must be able to add the same document")
	}

	// PUT alani atlarsa korunur; baska belge numarasina cakisan PUT 409.
	code, b = e.as(alice, "PUT", path, e.exp("E-Arsiv", 121, 0, nil))
	e.want(code, http.StatusOK, b, "put omitted")
	if g := decodeExpense(t, b); g.DocumentNo == nil || *g.DocumentNo != ettn {
		t.Fatalf("PUT without the field must keep it: %v", g.DocumentNo)
	}
	second := e.create(alice, e.exp("Digital 2", 50, 0, map[string]any{"client_uid": "d-3", "document_no": "1750051846_ABC2021000000123"}))
	code, b = e.as(alice, "PUT", fmt.Sprintf("/expenses/%d", second.ID), e.exp("Digital 2", 50, 0, map[string]any{"document_no": ettn}))
	e.want(code, http.StatusConflict, b, "put onto an existing document")

	// Numarasiz (fis/manuel) kayitlar birbirini engellemez.
	e.create(alice, e.exp("Fis 1", 5, 0, nil))
	e.create(alice, e.exp("Fis 2", 6, 0, nil))

	// Gecersiz numara 400.
	code, b = e.as(alice, "POST", "/expenses", e.exp("Kisa", 5, 0, map[string]any{"document_no": "0468"}))
	e.want(code, http.StatusBadRequest, b, "short number")

	// Toplu yukleme: mukerrer belge "error: duplicate_document" olur, partinin geri kalani yazilir.
	dup := e.exp("Kuyruk kopya", 120, 0, map[string]any{"client_uid": "q-dup", "document_no": ettn})
	fresh := e.exp("Kuyruk yeni", 30, 0, map[string]any{"client_uid": "q-new", "document_no": "11111111-2222-4333-8444-555555555555"})
	code, b = e.as(alice, "POST", "/expenses/bulk", map[string]any{"expenses": []any{dup, fresh}})
	e.want(code, http.StatusOK, b, "bulk")
	var res struct {
		Created, Failed int
		Results         []struct {
			Status string
			Error  string
		}
	}
	_ = json.Unmarshal(b, &res)
	if res.Created != 1 || res.Failed != 1 || res.Results[0].Status != "error" || res.Results[0].Error != "duplicate_document" || res.Results[1].Status != "created" {
		t.Fatalf("bulk duplicate handling: %s", b)
	}
}
