package main

import "testing"

func f64(v float64) *float64 { return &v }

func TestReconcileMatchingTotal(t *testing.T) {
	items := []expenseItem{{Name: "EKMEK", Amount: 5}, {Name: "SUT", Amount: 32.5}}
	out, review, total := reconcileItems(items, f64(37.5))
	if review || total != nil || len(out) != 2 {
		t.Fatalf("matching receipt: out=%v review=%v total=%v", out, review, total)
	}
}

func TestReconcileLegitDuplicateKept(t *testing.T) {
	// Iki gercek ekmek: toplam ikisini de iceriyor, dokunulmamali.
	items := []expenseItem{{Name: "EKMEK", Amount: 5}, {Name: "EKMEK", Amount: 5}, {Name: "SUT", Amount: 32.5}}
	out, review, _ := reconcileItems(items, f64(42.5))
	if review || len(out) != 3 {
		t.Fatalf("legit duplicate removed: %v review=%v", out, review)
	}
}

func TestReconcileDoubleReadRemoved(t *testing.T) {
	// Fis toplami 37,50; ekmek cift okunmus (5+5+32,5 = 42,5): fark 5 = tekrar eden kalem.
	items := []expenseItem{{Name: "EKMEK", Amount: 5}, {Name: "EKMEK", Amount: 5}, {Name: "SUT", Amount: 32.5}}
	out, review, total := reconcileItems(items, f64(37.5))
	if review || total != nil {
		t.Fatalf("review=%v total=%v", review, total)
	}
	if len(out) != 2 || out[0].Name != "EKMEK" || out[1].Name != "SUT" {
		t.Fatalf("out = %v", out)
	}
}

func TestReconcileDoubleReadWithOCRNoiseInName(t *testing.T) {
	items := []expenseItem{{Name: "SUT 1L TAM YAGLI", Amount: 34.5}, {Name: "SUT 1L TAM YAGL1", Amount: 34.5}, {Name: "EKMEK", Amount: 15}}
	out, review, _ := reconcileItems(items, f64(49.5))
	if review || len(out) != 2 {
		t.Fatalf("out = %v review=%v", out, review)
	}
}

func TestReconcileNoEvidenceKeepsItemAndFlags(t *testing.T) {
	// Fark (5) EKMEK'in fiyatina esit ama bitisik cift kaniti yok: silinmez, uyari verilir.
	items := []expenseItem{{Name: "EKMEK", Amount: 5}, {Name: "SUT", Amount: 32.5}, {Name: "PEYNIR", Amount: 60}}
	out, review, total := reconcileItems(items, f64(92.5))
	if !review || total == nil || *total != 97.5 || len(out) != 3 {
		t.Fatalf("out=%v review=%v total=%v", out, review, total)
	}
}

func TestReconcileUnclosableDifference(t *testing.T) {
	items := []expenseItem{{Name: "EKMEK", Amount: 5}, {Name: "SUT", Amount: 32.5}}
	out, review, total := reconcileItems(items, f64(100))
	if !review || total == nil || *total != 37.5 || len(out) != 2 {
		t.Fatalf("out=%v review=%v total=%v", out, review, total)
	}
}

func TestReconcileNoItemsOrNoTotal(t *testing.T) {
	if _, review, _ := reconcileItems(nil, f64(10)); review {
		t.Fatal("no items: must not flag")
	}
	if _, review, _ := reconcileItems([]expenseItem{{Name: "X", Amount: 1}}, nil); review {
		t.Fatal("no total: must not flag")
	}
}

func TestParseFlagsMismatchedReceipt(t *testing.T) {
	// parser_test.go'daki market fisinin kalemleri (5,00 + 32,50) 1.250,75 ile tutmaz.
	text := `BİM BİRLEŞİK MAĞAZALAR A.Ş.
TARİH: 12.05.2026
EKMEK        *5,00
SÜT          *32,50
TOPLAM       *1.250,75`
	r := Parse(text, testCats, now)
	if !r.NeedsReview || r.ItemsTotal == nil || *r.ItemsTotal != 37.5 {
		t.Fatalf("review=%v itemsTotal=%v", r.NeedsReview, r.ItemsTotal)
	}
}

func TestParseConsistentReceiptNoReview(t *testing.T) {
	text := `BİM BİRLEŞİK MAĞAZALAR A.Ş.
TARİH: 12.05.2026
EKMEK        *5,00
SÜT          *32,50
TOPLAM       *37,50`
	r := Parse(text, testCats, now)
	if r.NeedsReview || r.ItemsTotal != nil {
		t.Fatalf("review=%v itemsTotal=%v", r.NeedsReview, r.ItemsTotal)
	}
}
