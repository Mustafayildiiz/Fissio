package main

import (
	"math"
	"strings"
	"testing"
)

// Uc dogruluk sorunu: (1) `$` -> S-cedilla glif hatasi, (2) mukerrer satirlar,
// (3) kalemler toplami ile fis toplaminin uyusmamasi.

// --- 1. Glif duzeltme ---------------------------------------------------------------------

func TestFixTurkishGlyphs(t *testing.T) {
	cases := map[string]string{
		// pozitif: harfe bitisik `$` harftir
		"Fİ$":                "FİŞ",
		"Fİ$ NO:0298":        "FİŞ NO:0298",
		"PE$İN":              "PEŞİN",
		"KA$AR PEYNİR":       "KAŞAR PEYNİR",
		"$EKER 1KG":          "ŞEKER 1KG",
		"BİM A.$.":           "BİM A.Ş.",
		"MİGROS TİCARET A.$": "MİGROS TİCARET A.Ş",
		"ABC LTD.$Tİ.":       "ABC LTD.ŞTİ.",
		"TE$EKKÜRLER":        "TEŞEKKÜRLER",
		"pe$in fiyatına":     "peşin fiyatına",
		"KA$AR %08 *120,00":  "KAŞAR %08 *120,00",
		// negatif: rakama bitisik / yalniz `$` fiyat sutunu isaretidir
		"$12,50":             "$12,50",
		"EKMEK %08 $3,95":    "EKMEK %08 $3,95",
		"TOPLAM $45,00":      "TOPLAM $45,00",
		"KEK 35 G %08 *$070": "KEK 35 G %08 *$070",
		"SUT %08 $":          "SUT %08 $",
		"US$ 1,00":           "US$ 1,00", // doviz kodu
		"FIYAT US$":          "FIYAT US$",
		"KU$ YEMİ":           "KUŞ YEMİ", // doviz kodu degil
		"BU$AN 5,00":         "BUŞAN 5,00",
	}
	for in, want := range cases {
		if got := fixTurkishGlyphs(in); got != want {
			t.Errorf("fixTurkishGlyphs(%q) = %q, want %q", in, got, want)
		}
		if again := fixTurkishGlyphs(fixTurkishGlyphs(in)); again != fixTurkishGlyphs(in) {
			t.Errorf("not idempotent: %q", in)
		}
	}
}

func TestParseFixesDollarGlyphInMerchantAndItems(t *testing.T) {
	r := Parse("BİM BİRLEŞİK MAĞAZALAR A.$.\nTARİH: 12.05.2026\nKA$AR PEYNİR *45,00\nTOPLAM *45,00", testCats, now)
	if r.Merchant != "BİM BİRLEŞİK MAĞAZALAR A.Ş." {
		t.Fatalf("merchant = %q", r.Merchant)
	}
	if len(r.Items) != 1 || r.Items[0].Name != "KAŞAR PEYNİR" || r.Items[0].Amount != 45 {
		t.Fatalf("items = %+v", r.Items)
	}
	if r.Amount == nil || *r.Amount != 45 {
		t.Fatalf("amount = %v", r.Amount)
	}
}

// --- 2. Mukerrer satirlar ----------------------------------------------------------------

func TestJaroWinkler(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want float64
	}{{"martha", "marhta", 0.9611}, {"dixon", "dicksonx", 0.8133}, {"abc", "abc", 1}, {"abc", "", 0}} {
		if got := jaroWinkler(c.a, c.b); math.Abs(got-c.want) > 0.001 {
			t.Errorf("jaroWinkler(%q,%q) = %.4f, want %.4f", c.a, c.b, got, c.want)
		}
	}
}

func TestMergePageTextsRemovesLeftCroppedOverlap(t *testing.T) {
	// Ikinci fotograf satirlarin solunu kesmis: "ETI KA" kadraj disinda kalmis.
	p1 := "BIM\nSUT 1,00\nETI KARAM GURME 50 G 1,75\nSUT AROMALI 1,00"
	p2 := "RAM GURME 50 G 1,75\nAROMALI 1,00\nKEK 0,70\nTOPLAM 4,45"
	got := mergePageTexts([]string{p1, p2})
	want := "BIM\nSUT 1,00\nETI KARAM GURME 50 G 1,75\nSUT AROMALI 1,00\nKEK 0,70\nTOPLAM 4,45"
	if got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
	r := Parse(got, testCats, now)
	if r.NeedsReview || len(r.Items) != 4 {
		t.Fatalf("items = %+v review = %v", r.Items, r.NeedsReview)
	}
}

func TestFuzzyLineEqualRequiresSamePrice(t *testing.T) {
	if fuzzyLineEqual("ETI KARAM GURME 50 G 1,75", "RAM GURME 50 G 2,75") {
		t.Fatal("cropped line with different price must not match")
	}
	if fuzzyLineEqual("SUT AROMALI", "AROMALI") {
		t.Fatal("suffix match without an amount must not match")
	}
	if !fuzzyLineEqual("ETİ KARAM GURME 50 G 1,75", "ETIKARAM GURNE 50G 1,75") {
		t.Fatal("noisy re-read must match")
	}
}

func TestMergeThenReconcileRemovesSingleSeamDuplicate(t *testing.T) {
	// Tek satirlik dikis cakismasi merge'de korunur (mesru tekrar olabilir); toplam cift okumayi
	// kanitlar ve mutabakat temizler.
	merged := mergePageTexts([]string{"MIGROS\nEKMEK 15,00\nSUT 1L 34,50", "SUT 1L 34,50\nYUMURTA 60,00\nTOPLAM 109,50"})
	r := Parse(merged, testCats, now)
	if r.NeedsReview || len(r.Items) != 3 {
		t.Fatalf("items = %+v review = %v", r.Items, r.NeedsReview)
	}
	if r.Reconciliation == nil || r.Reconciliation.Status != recDuplicate {
		t.Fatalf("reconciliation = %+v", r.Reconciliation)
	}
}

// --- 3. Toplam mutabakati ----------------------------------------------------------------

const receiptWithSummary = `MİGROS TİCARET A.$.
TARİH: 12.05.2026
KA$AR PEYNİR 500G      *120,00
ÇAY
2 ADET X 15,00 = 30,00
KARTON SÜT 1L          *25,00
EKMEK                  *10,00
1 X 10,00
ARA TOPLAM             *185,00
İNDİRİM                -5,00
TOPKDV                 *13,70
TOPLAM                 *180,00
NAKİT                  *200,00
PARA ÜSTÜ              *20,00`

func TestParseMultiLineVatDiscountReceipt(t *testing.T) {
	r := Parse(receiptWithSummary, testCats, now)
	if r.Amount == nil || *r.Amount != 180 {
		t.Fatalf("amount = %v (resolveTotal must not replace it with the subtotal)", r.Amount)
	}
	want := []expenseItem{{"KAŞAR PEYNİR 500G", 120}, {"ÇAY", 30}, {"KARTON SÜT 1L", 25}, {"EKMEK", 10}}
	if len(r.Items) != len(want) {
		t.Fatalf("items = %+v", r.Items)
	}
	for i, w := range want {
		if r.Items[i] != w {
			t.Fatalf("item %d = %+v, want %+v (all = %+v)", i, r.Items[i], w, r.Items)
		}
	}
	if r.NeedsReview || r.Reconciliation == nil || r.Reconciliation.Status != recDiscount {
		t.Fatalf("review = %v reconciliation = %+v", r.NeedsReview, r.Reconciliation)
	}
	if r.DiscountTotal == nil || *r.DiscountTotal != 5 {
		t.Fatalf("discount_total = %v", r.DiscountTotal)
	}
	s := r.Summary
	if s == nil || s.Subtotal == nil || *s.Subtotal != 185 || len(s.Discounts) != 1 || s.Discounts[0] != 5 ||
		s.VATTotal == nil || *s.VATTotal != 13.70 || s.PaidCash == nil || *s.PaidCash != 200 ||
		s.Change == nil || *s.Change != 20 {
		t.Fatalf("summary = %+v", s)
	}
}

func TestSummaryLinesNeverBecomeItems(t *testing.T) {
	text := "MARKET\nEKMEK 10,00\nSUT 20,00\nARATOPLAM 30,00\nINDIRIM 3,00\nKDV %1 0,27\nTOPLAM 27,00\nKREDIKARTI 27,00\nPARAUSTU 0,00"
	r := Parse(text, testCats, now)
	if len(r.Items) != 2 || r.Items[0].Name != "EKMEK" || r.Items[1].Name != "SUT" {
		t.Fatalf("items = %+v", r.Items)
	}
	if r.Amount == nil || *r.Amount != 27 || r.NeedsReview {
		t.Fatalf("amount = %v review = %v rec = %+v", r.Amount, r.NeedsReview, r.Reconciliation)
	}
	if r.Summary == nil || r.Summary.PaidCard == nil || *r.Summary.PaidCard != 27 {
		t.Fatalf("summary = %+v", r.Summary)
	}
}

func TestLabelClassification(t *testing.T) {
	for _, l := range []string{"ARA TOPLAM 30,00", "ARATOPLAM 30,00", "ARA T0PLAM 30,00"} {
		if !isSubtotalLine(l) || isTotalLabel(l) {
			t.Errorf("%q: subtotal=%v total=%v", l, isSubtotalLine(l), isTotalLabel(l))
		}
	}
	for _, l := range []string{"İNDİRİM -5,00", "ISKONTO 2,00", "KAMPANYA -1,50", "TOPLAM İNDİRİM 5,00"} {
		if !isDiscountLine(l) || isTotalLabel(l) {
			t.Errorf("%q: discount=%v total=%v", l, isDiscountLine(l), isTotalLabel(l))
		}
	}
	for _, l := range []string{"TOPLAM 27,00", "GENEL TOPLAM 27,00", "TOP *480.00"} {
		if !isTotalLabel(l) {
			t.Errorf("%q must be a total label", l)
		}
	}
	// Kisa etiketler ve kelime sinirini asan bosluksuz eslesmeler urun adlarini dusurmemeli.
	for _, l := range []string{
		"KARTON SÜT 1L 25,00", "KARTOPU KEK 3,50", "MAYONEZ 20,00", "BANKALAR CADDESI SİMİT 5,00",
		"KARA TOPRAK 45,00", "İNDİRİMLİ FİYAT 13,00",
	} {
		if strong, weak := nonItemLabel(l); strong || weak {
			t.Errorf("%q wrongly treated as a label (strong=%v weak=%v)", l, strong, weak)
		}
	}
	for _, l := range []string{"KAMPANYA İNDİRİMİ 1,50", "LNDIRIM 2,00", "ISKONTOSU 3,00"} {
		if !isDiscountLine(l) {
			t.Errorf("%q must be a discount line", l)
		}
	}
	for _, l := range []string{"KREDİ KARTI 25,00", "KREDIKARTI 25,00", "PARA ÜSTÜ 1,00", "FİŞ NO:0298", "NAKİT 50,00", "TOPKDV 1,96"} {
		if strong, _ := nonItemLabel(l); !strong {
			t.Errorf("%q must be a strong label", l)
		}
	}
}

func TestQtyLines(t *testing.T) {
	cases := []struct {
		name, text string
		want       []expenseItem
	}{
		{"unit price below item is info", "ÇAY 30,00\n2 ADET X 15,00\nTOPLAM 30,00", []expenseItem{{"ÇAY", 30}}},
		{"net below item is info", "ÇAY 30,00\n2 ADET X 15,00 = 30,00\nTOPLAM 30,00", []expenseItem{{"ÇAY", 30}}},
		{"name above, net on qty line", "ÇAY\n2 ADET X 15,00 = 30,00\nTOPLAM 30,00", []expenseItem{{"ÇAY", 30}}},
		{"name above, net without equals", "ÇAY\n2 AD X 15,00   30,00\nTOPLAM 30,00", []expenseItem{{"ÇAY", 30}}},
		{"name above, unit only", "ÇAY\n2 ADET X 15,00\nTOPLAM 30,00", []expenseItem{{"ÇAY", 30}}},
		{"unit-priced item corrected to net", "ÇAY 15,00\n2 ADET X 15,00 = 30,00\nTOPLAM 30,00", []expenseItem{{"ÇAY", 30}}},
		{"weighed item", "DOMATES\n0,535 KG X 40,00 = 21,40\nTOPLAM 21,40", []expenseItem{{"DOMATES", 21.40}}},
		{"BIM qty line before item", "3X1,00\nPOPKEK MUZLU %08 3,00\nTOPLAM 3,00", []expenseItem{{"POPKEK MUZLU", 3}}},
		{"1L is not a qty line", "1L SUT 34,50\nTOPLAM 34,50", []expenseItem{{"1L SUT", 34.50}}},
	}
	for _, c := range cases {
		r := Parse("MARKET\n12.05.2026\n"+c.text, testCats, now)
		if len(r.Items) != len(c.want) {
			t.Errorf("%s: items = %+v", c.name, r.Items)
			continue
		}
		for i := range c.want {
			if r.Items[i] != c.want[i] {
				t.Errorf("%s: item %d = %+v, want %+v", c.name, i, r.Items[i], c.want[i])
			}
		}
		if r.NeedsReview {
			t.Errorf("%s: unexpected review %+v", c.name, r.Reconciliation)
		}
	}
}

func TestReconcileStatuses(t *testing.T) {
	items := func() []expenseItem {
		return []expenseItem{{Name: "EKMEK", Amount: 5}, {Name: "SUT", Amount: 32.5}, {Name: "PEYNIR", Amount: 60}}
	}

	// Fazla, kanit yok: silinmez, supheli kalem raporlanir.
	o := reconcile(items(), f64(92.5), 0, nil)
	if !o.needsReview || len(o.items) != 3 || o.info.SuspectIndex == nil || *o.info.SuspectIndex != 0 || o.info.Reason != "excess_equals_item" {
		t.Fatalf("excess: %+v %+v", o, o.info)
	}
	// Eksik ve fark tek bir kalemin fiyati: ikinci adet okunmamis olabilir.
	o = reconcile(items(), f64(157.5), 0, nil)
	if !o.needsReview || o.info.SuspectIndex == nil || *o.info.SuspectIndex != 2 || o.info.Reason != "missing_equals_item" {
		t.Fatalf("missing item: %+v", o.info)
	}
	// Eksik ve fark atlanan etiketli satira esit.
	o = reconcile(items(), f64(112.5), 0, []expenseItem{{Name: "BANKA KAMPANYA URUNU", Amount: 15}})
	if !o.needsReview || !strings.HasPrefix(o.info.Reason, "missing_equals_skipped_line") {
		t.Fatalf("skipped line: %+v", o.info)
	}
	// Indirim farki kapatir.
	o = reconcile(items(), f64(87.5), 10, nil)
	if o.needsReview || o.discount != 10 || o.info.Status != recDiscount {
		t.Fatalf("discount: %+v %+v", o, o.info)
	}
	// Indirim zaten kalemlere yansimis: dusulmez.
	o = reconcile(items(), f64(97.5), 10, nil)
	if o.needsReview || o.discount != 0 || o.info.Status != recOK {
		t.Fatalf("discount already applied: %+v %+v", o, o.info)
	}
	// Bitisik cift okuma: silinir.
	o = reconcile([]expenseItem{{Name: "SUT 1L", Amount: 34.5}, {Name: "SUT 1L", Amount: 34.5}, {Name: "EKMEK", Amount: 15}}, f64(49.5), 0, nil)
	if o.needsReview || len(o.items) != 2 || o.info.Status != recDuplicate {
		t.Fatalf("duplicate: %+v %+v", o, o.info)
	}
}

func TestParseReportsSkippedLabelLine(t *testing.T) {
	r := Parse("MARKET\nEKMEK 10,00\nBANKA KAMPANYA URUNU 15,00\nTOPLAM 25,00", testCats, now)
	if !r.NeedsReview || r.Reconciliation == nil || !strings.HasPrefix(r.Reconciliation.Reason, "missing_equals_skipped_line") {
		t.Fatalf("review = %v rec = %+v items = %+v", r.NeedsReview, r.Reconciliation, r.Items)
	}
}
