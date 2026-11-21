package receiptparse

import (
	"reflect"
	"testing"
)

func TestSplitLinesIntegerCurrency(t *testing.T) {
	cases := map[string]string{
		"Toplam 355TRY":         "Toplam 355,00",
		"Ara Toplam 665 TRY":    "Ara Toplam 665,00",
		"Teslimat Ücreti 0 TRY": "Teslimat Ücreti 0,00",
		"Hediye -310 TRY":       "Hediye -310,00",
		"Hediye - 310 TRY":      "Hediye - 310,00", // negativeAmountRe "-\s*tutar" biçimini zaten indirim sayar
		"Toplam 1.250 TL":       "Toplam 1.250,00",
		"Toplam 1.250,50 TL":    "Toplam 1.250,50 TL", // ondalıklı ve boşluklu: dokunulmaz (eski davranış)
		"Toplam 24.90TL":        "Toplam 24.90",
		"Toplam 24,90 ₺":        "Toplam 24,90 ₺",
		"Toplam 355₺":           "Toplam 355,00",
		"355TRY":                "355,00",
		"10 TL indirim kuponu":  "10 TL indirim kuponu", // satır sonunda değil: dokunulmaz
		"Tel: 0850 123 45 67":   "Tel: 0850 123 45 67",
		"Sipariş No 1234":       "Sipariş No 1234",
		"Toplam 355 try":        "Toplam 355,00",
		"Fiyat 12,5 TRY":        "Fiyat 12,5 TRY", // ondalık parçası var (tek hane): tamsayı kuralı uygulanmaz
	}
	for in, want := range cases {
		got := splitLines(in)
		if len(got) != 1 || got[0] != want {
			t.Errorf("splitLines(%q) = %v, want [%q]", in, got, want)
		}
	}
}

func TestParseGetirYemekOrderSummary(t *testing.T) {
	text := "GetirYemek\nTavukburger® Menü Alana Tavukburger® Menü Hediye - (Adet: 1)\nSipariş Özeti\n" +
		"Ara Toplam 665 TRY\nTeslimat Ücreti 0 TRY\nTavukburger® Menü Alana Tavukburger® Menü Hediye -310 TRY\nToplam 355TRY"
	r := Parse(text, goldenCats(), now)
	if r.Amount == nil || cents(*r.Amount) != 35500 {
		t.Fatalf("amount = %v, want 355", r.Amount)
	}
	if r.Summary == nil || r.Summary.Subtotal == nil || cents(*r.Summary.Subtotal) != 66500 {
		t.Fatalf("subtotal = %+v", r.Summary)
	}
	if r.DiscountTotal == nil || cents(*r.DiscountTotal) != 31000 {
		t.Fatalf("discount = %v, want 310 (kampanya satırı adında 'indirim' geçmese de negatif tutar indirimdir)", r.DiscountTotal)
	}
	if len(r.Items) != 0 || r.NeedsReview {
		t.Fatalf("fiyatsız ürün satırı kalem olmamalı: items=%v review=%v", r.Items, r.NeedsReview)
	}
	if r.Merchant != "GetirYemek" {
		t.Fatalf("merchant = %q", r.Merchant)
	}
}

func TestParseIntegerCurrencyDoesNotBreakDecimalReceipts(t *testing.T) {
	a := Parse("MARKET\nEKMEK 10,00\nSUT 20,00\nTOPLAM 30,00 TL", goldenCats(), now)
	b := Parse("MARKET\nEKMEK 10,00\nSUT 20,00\nTOPLAM 30,00", goldenCats(), now)
	if !reflect.DeepEqual(a.Items, b.Items) || a.Amount == nil || *a.Amount != *b.Amount {
		t.Fatalf("TL son eki sonucu değiştirmemeli: %+v vs %+v", a, b)
	}
}
