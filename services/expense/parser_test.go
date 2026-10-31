package main

import (
	"testing"
	"time"
)

var testCats = []Category{
	{ID: 1, Name: "Market", Keywords: []string{"bim", "migros", "a101", "şok"}},
	{ID: 2, Name: "Akaryakıt", Keywords: []string{"opet", "shell", "bp", "petrol ofisi"}},
	{ID: 3, Name: "Diğer"},
}

var now = time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)

func TestParseMarketReceipt(t *testing.T) {
	text := `BİM BİRLEŞİK MAĞAZALAR A.Ş.
Atatürk Mah. No:5 İstanbul
TARİH: 12.05.2026  SAAT: 14:35
EKMEK        *5,00
SÜT          *32,50
TOPKDV       %1  1,20
TOPLAM       *1.250,75
KREDİ KARTI  1.250,75`
	r := Parse(text, testCats, now)
	if r.Amount == nil || *r.Amount != 1250.75 {
		t.Fatalf("amount = %v", r.Amount)
	}
	if r.Date == nil || *r.Date != "2026-05-12" {
		t.Fatalf("date = %v", r.Date)
	}
	if r.CategoryName != "Market" {
		t.Fatalf("category = %s", r.CategoryName)
	}
	if r.Merchant != "BİM BİRLEŞİK MAĞAZALAR A.Ş." {
		t.Fatalf("merchant = %q", r.Merchant)
	}
	if r.NeedsManual {
		t.Fatal("needs_manual should be false")
	}
}

func TestParseFuelReceiptAmountOnNextLine(t *testing.T) {
	text := "OPET\nİstasyon 123\n3.10.2026\nGENEL TOPLAM\n845,00"
	r := Parse(text, testCats, now)
	if r.Amount == nil || *r.Amount != 845 {
		t.Fatalf("amount = %v", r.Amount)
	}
	if r.CategoryName != "Akaryakıt" {
		t.Fatalf("category = %s", r.CategoryName)
	}
}

func TestDateNotMistakenForAmount(t *testing.T) {
	r := Parse("Market\n12.05.2026 14:35\nTOPLAM 20,00", testCats, now)
	if r.Amount == nil || *r.Amount != 20 {
		t.Fatalf("amount = %v", r.Amount)
	}
}

func TestInvalidDateRejected(t *testing.T) {
	r := Parse("X\n31.02.2026\nTOPLAM 10,00", testCats, now)
	if r.Date != nil {
		t.Fatalf("date should be nil, got %s", *r.Date)
	}
}

func TestNoAmountNeedsManual(t *testing.T) {
	r := Parse("okunamayan metin", testCats, now)
	if !r.NeedsManual || r.Amount != nil {
		t.Fatal("expected needs_manual")
	}
	if r.CategoryName != "Diğer" || r.CategoryID != 3 {
		t.Fatalf("fallback category = %d %s", r.CategoryID, r.CategoryName)
	}
}

func TestWordBoundary(t *testing.T) {
	if containsWord("abpx", "bp") {
		t.Fatal("bp must not match inside abpx")
	}
	if !containsWord("bp istasyonu", "bp") {
		t.Fatal("bp should match")
	}
}

func TestParseAmountFormats(t *testing.T) {
	cases := map[string]float64{"125,50": 125.5, "125.50": 125.5, "1.250,50": 1250.5, "12.345.678,90": 12345678.9}
	for in, want := range cases {
		got, ok := parseAmount(in)
		if !ok || got != want {
			t.Errorf("parseAmount(%q) = %v, want %v", in, got, want)
		}
	}
}

