package receiptparse

import (
	"strings"
	"testing"
)

func TestIsCancelMarker(t *testing.T) {
	for _, l := range []string{"** IPTAL **", "IPTAL**", "IPTAL", "iptai", "** IADE **"} {
		if !isCancelMarker(l) {
			t.Errorf("%q must be a cancel marker", l)
		}
	}
	for _, l := range []string{"IPTAL EDILEN 12,50", "KIVI 59,22", "IPTALIYE KAHVE", "TOPLAM"} {
		if isCancelMarker(l) {
			t.Errorf("%q must NOT be a cancel marker", l)
		}
	}
}

// Satis + "** IPTAL **" + (miktar satiri) + geri alma satiri: kalem ve geri alma birlikte dusulur; toplam bozulmaz.
func TestCancelReversalRemovesTheSoldItem(t *testing.T) {
	clean := strings.Join([]string{
		"MARKET",
		"12.05.2026",
		"ELMA %01 *54,79",
		"KIVI %01 *69,22",
		"** IPTAL **",
		"-0,770 X 89,90 TL",
		"KIVI %01 *-69,22",
		"HAVUC %01 *18,76",
		"TOPLAM *73,55",
	}, "\n")
	r := Parse(clean, goldenCats(), now)
	if len(r.Items) != 2 || r.Items[0].Name != "ELMA" || r.Items[1].Name != "HAVUC" {
		t.Fatalf("cancelled item must be gone, got %+v", r.Items)
	}
	if r.NeedsReview || r.DiscountTotal != nil {
		t.Fatalf("a reversal is neither a mismatch nor a discount: review=%v discount=%v", r.NeedsReview, r.DiscountTotal)
	}

	// OCR geri alma satirinin tutarini bozmus (69,22 -> 59,22) ve eksi isaretini okumamis: ad benzerligiyle yine dusulur.
	noisy := strings.ReplaceAll(strings.ReplaceAll(clean, "KIVI %01 *-69,22", "KIVA 59,22"), "KIVI %01 *69,22", "KIVI *69,22")
	r = Parse(noisy, goldenCats(), now)
	if len(r.Items) != 2 {
		t.Fatalf("name-similar reversal must still cancel the sold item, got %+v", r.Items)
	}

	// Eslesme yoksa hicbir sey dusulmez (mutabakat uyusmazligi bayraklar).
	items := []Item{{Name: "SUT", Amount: 10}}
	if got := applyReversal(items, "PEYNIR", 99); len(got) != 1 {
		t.Fatalf("unmatched reversal must not drop anything: %+v", got)
	}
}

func TestCurrencySuffixAndGluedTime(t *testing.T) {
	r := Parse("Burcu Mayonez 1 5.00t\nBurcu Ketcap 7,50TL\nToplam: 12,50", goldenCats(), now)
	if len(r.Items) != 2 || r.Items[0].Amount != 5 || r.Items[1].Amount != 7.5 {
		t.Fatalf("currency suffix must be dropped from amounts: %+v", r.Items)
	}
	if r.Amount == nil || *r.Amount != 12.5 {
		t.Fatalf("total = %v", r.Amount)
	}
	r = Parse("18/10/202617:06\nKahve 40,00\nTOPLAM 40,00", goldenCats(), now)
	if r.Date == nil || *r.Date != "2026-10-18" {
		t.Fatalf("a time glued to the year must not hide the date: %v", r.Date)
	}
}

func TestAmountAboveLabelAndStackedVAT(t *testing.T) {
	// Tutar etiketin USTUNDE (uygulama fisleri / OCR satir kaymasi).
	r := Parse("Mağaza\nKahve 40,00\n40.00\nToplam:", goldenCats(), now)
	if r.Amount == nil || *r.Amount != 40 {
		t.Fatalf("amount-only line above the label: %v", r.Amount)
	}
	// KDV satiri hem KDV'yi hem toplami tasir, TOPLAM etiketi bos.
	r = Parse("MARKET\nEKMEK %01 1,25\nSUT %08 3,45\nTOPKDV 307.85 22,79\nTOPLAM", goldenCats(), now)
	if r.Amount == nil || *r.Amount != 307.85 {
		t.Fatalf("stacked VAT+total line: %v", r.Amount)
	}
	if hi, lo, ok := vatAndTotal([]float64{22.79, 307.85}); !ok || hi != 307.85 || lo != 22.79 {
		t.Fatalf("vatAndTotal = %v %v %v", hi, lo, ok)
	}
	if _, _, ok := vatAndTotal([]float64{10, 12}); ok {
		t.Fatal("similar amounts are not a VAT+total pair")
	}
}

func TestMerchantIsNeverAnItemRow(t *testing.T) {
	// Baslik kirpik: ilk satirlar urun satiri; isletme adi uydurulmaz.
	r := Parse("KASAR PEYNIR %01 *139,90\nSUT %08 *35,95\nTOPLAM *175,85", goldenCats(), now)
	if r.Merchant != "" {
		t.Fatalf("cropped header must not turn an item row into a merchant: %q", r.Merchant)
	}
	// Adres/not satirlari ve baslik oldugu gibi korunur.
	r = Parse("Uber Eats\ntrendyolgo\nÜrün Adet Tutar\nDöner 240,00\nToplam: 240,00", goldenCats(), now)
	if !strings.Contains(strings.ToLower(r.Merchant), "uber") {
		t.Fatalf("merchant = %q", r.Merchant)
	}
}

// Kalem tutarlari KDV'siz yazilan fatura: toplam "Odenecek Tutar" etiketli ve (toplam - kalemler) = KDV -> uyusmazlik degil.
func TestVATExcludedInvoiceIsNotAMismatch(t *testing.T) {
	text := "ACME A.S.\n05.10.2026\nSut 60,00 TL\nEkmek 15,00 TL\nMal Hizmet Toplam Tutarı 75,00 TL\nHesaplanan KDV (%10) 7,50 TL\nÖdenecek Tutar 82,50 TL"
	r := Parse(text, goldenCats(), now)
	if r.Amount == nil || *r.Amount != 82.5 {
		t.Fatalf("labeled payable amount must win over the items subtotal: %v", r.Amount)
	}
	if r.NeedsReview || r.Reconciliation == nil || r.Reconciliation.Reason != "items_exclude_vat" {
		t.Fatalf("VAT-excluded items must reconcile: review=%v rec=%+v", r.NeedsReview, r.Reconciliation)
	}
	// Etiket yoksa tesadufen KDV'ye esit fark ONAYLANMAZ.
	unlabeled := "ACME A.S.\n05.10.2026\nSut 60,00\nEkmek 15,00\nHesaplanan KDV 7,50\nToplam 82,50"
	if r := Parse(unlabeled, goldenCats(), now); !r.NeedsReview {
		t.Fatal("without a payable/grand-total label a gap equal to the VAT must stay flagged")
	}
}
