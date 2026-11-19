package main

import (
	"encoding/json"
	"testing"
)

// Kural ogrenme (collectRuleUpdates) ve kalem saklama/dogrulama testleri: package main'in istek tiplerine
// (expenseInput) baglidir; ayristirma/kategorilendirme testleri internal/receiptparse'tadir.

// fullCats: yeni taksonomi (db.go seed) - id'ler sirayla.
var fullCats = []Category{
	{ID: 1, Name: "Market / Gıda"},
	{ID: 2, Name: "Restoran / Kafe"},
	{ID: 3, Name: "Akaryakıt / Ulaşım"},
	{ID: 4, Name: "Giyim"},
	{ID: 5, Name: "Elektronik"},
	{ID: 6, Name: "Sağlık / Eczane"},
	{ID: 7, Name: "Fatura / Abonelik"},
	{ID: 8, Name: "Ev / Yaşam"},
	{ID: 9, Name: "Kişisel Bakım"},
	{ID: 10, Name: "Eğlence / Hobi"},
	{ID: 11, Name: "Diğer"},
}

func TestCollectRuleUpdates(t *testing.T) {
	in := expenseInput{
		Merchant: "YILDIZ GIDA", CategoryID: 2, SuggestedCategoryID: 1,
		Items: []expenseItem{
			{Name: "EKMEK 1ADET", CategoryID: 8, SuggestedCategoryID: 1}, // duzeltildi
			{Name: "SÜT 1L", CategoryID: 1, SuggestedCategoryID: 1},      // onaylandi
			{Name: "ELLE EKLENDI", CategoryID: 9},                        // onerisiz
			{Name: "123", CategoryID: 2, SuggestedCategoryID: 1},         // bos anahtar
			{Name: "EKMEK", CategoryID: 8, SuggestedCategoryID: 1},       // ayni anahtar tekrari
			{Name: "SUTSUZ", CategoryID: 0, SuggestedCategoryID: 1},      // atanmamis
		},
	}
	got := collectRuleUpdates(in)
	want := []ruleUpdate{{"merchant", "yildiz gida", 2}, {"item", "ekmek", 8}}
	if len(got) != len(want) {
		t.Fatalf("updates = %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("update %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	// Onerilen = secilen ya da oneri yok: kural yok.
	if u := collectRuleUpdates(expenseInput{Merchant: "X MARKET", CategoryID: 1, SuggestedCategoryID: 1}); len(u) != 0 {
		t.Errorf("confirmed suggestion produced %+v", u)
	}
	if u := collectRuleUpdates(expenseInput{Merchant: "X MARKET", CategoryID: 1}); len(u) != 0 {
		t.Errorf("manual choice produced %+v", u)
	}
}

// ---- API / saklama ----

func TestItemsForStorageDropsTransientFields(t *testing.T) {
	in := []expenseItem{{Name: "SÜT", Amount: 30, CategoryID: 1, CategoryName: "Market / Gıda", CategoryConfidence: 0.9,
		CategorySource: "keyword", CategoryReview: true, SuggestedCategoryID: 2}}
	b, _ := json.Marshal(itemsForStorage(in))
	if string(b) != `[{"name":"SÜT","amount":30,"category_id":1}]` {
		t.Fatalf("stored = %s", b)
	}
	// Eski satirlar (kategorisiz) sorunsuz okunur ve yazilir.
	var old []expenseItem
	if err := json.Unmarshal([]byte(`[{"name":"EKMEK","amount":5}]`), &old); err != nil || old[0].CategoryID != 0 {
		t.Fatalf("legacy row: %v %+v", err, old)
	}
	if b, _ := json.Marshal(itemsForStorage(old)); string(b) != `[{"name":"EKMEK","amount":5}]` {
		t.Fatalf("legacy stored = %s", b)
	}
}

func TestItemCategoriesValid(t *testing.T) {
	if !itemCategoriesValid([]expenseItem{{Name: "a", CategoryID: 0}, {Name: "b", CategoryID: 3}}, fullCats) {
		t.Fatal("known / unassigned ids must be valid")
	}
	if itemCategoriesValid([]expenseItem{{Name: "a", CategoryID: 99}}, fullCats) {
		t.Fatal("unknown id must be invalid")
	}
}

func TestValidateRejectsNegativeItemCategory(t *testing.T) {
	in := expenseInput{Amount: 10, Date: "2026-05-12", CategoryID: 1, Items: []expenseItem{{Name: "a", Amount: 1, CategoryID: -1}}}
	if _, msg := in.validate(); msg == "" {
		t.Fatal("negative item category_id must be rejected")
	}
}
