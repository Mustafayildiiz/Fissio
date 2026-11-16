package main

import "testing"

func TestNormalizeOCR(t *testing.T) {
	cases := map[string]string{
		"t0plam *49,50":    "toplam *49,50",
		"migr0s":           "migros",
		"0pet":             "opet",
		"t0pkdv %1 1,20":   "topkdv %1 1,20",
		"a101 market":      "a101 market", // harf+cok rakam: dokunma
		"500g domates":     "500g domates",
		"1.250,75":         "1.250,75",
		"tarih 12.05.2026": "tarih 12.05.2026",
		"ekmek 15,00":      "ekmek 15,00",
		"sut 1l tam yagli": "sut 1l tam yagli", // 1l: 1 harf, dokunma
	}
	for in, want := range cases {
		if got := normalizeOCR(in); got != want {
			t.Errorf("normalizeOCR(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFuzzyTokenMatch(t *testing.T) {
	yes := [][2]string{
		{"toplan *49,50", "toplam"},
		{"odeneck 49,50", "odenecek"},
		{"petrol ofsi", "petrol ofisi"},
	}
	for _, c := range yes {
		if !fuzzyTokenMatch(c[0], c[1], fuzzyMinLen) {
			t.Errorf("fuzzyTokenMatch(%q, %q) = false, want true", c[0], c[1])
		}
	}
	no := [][2]string{
		{"bin market", "bim"},       // kisa kelime: yalnizca tam eslesme
		{"topkdv", "toplam"},        // 3 duzenleme
		{"domates salca", "toplam"}, // alakasiz
		{"kartal", "kart"},          // kisa kelime (4): bulanik yok
	}
	for _, c := range no {
		if fuzzyTokenMatch(c[0], c[1], fuzzyMinLen) {
			t.Errorf("fuzzyTokenMatch(%q, %q) = true, want false", c[0], c[1])
		}
	}
}

func TestHasKeywordKeepsSubstringBehaviour(t *testing.T) {
	// Eski davranis (alt dize) korunmali: "KREDI KARTI" -> "kart", "TOPKDV" -> "kdv".
	if !hasKeyword("KREDİ KARTI 49,50", "kart", fuzzyMinLen) {
		t.Error("kart must match inside karti")
	}
	if !hasKeyword("TOPKDV %1 1,20", "kdv", fuzzyMinLen) {
		t.Error("kdv must match inside topkdv")
	}
}

func TestParseBozukYazimlar(t *testing.T) {
	text := `MIGR0S TICARET A.S.
TARIH: 12.05.2026
EKMEK        *5,00
SUT          *32,50
T0PLAM       *37,50
KREDI KARTI  37,50`
	r := Parse(text, testCats, now)
	if r.Amount == nil || *r.Amount != 37.5 {
		t.Fatalf("T0PLAM amount = %v", r.Amount)
	}
	if r.CategoryName != "Market" {
		t.Fatalf("MIGR0S category = %s", r.CategoryName)
	}
	if r.Merchant != "MIGR0S TICARET A.S." {
		t.Fatalf("merchant must stay as read, got %q", r.Merchant)
	}
	if r.NeedsReview {
		t.Fatalf("items 5,00+32,50 match total 37,50, got review %+v", r.ItemsTotal)
	}

	r = Parse("0PET PETROL\n12.05.2026\nTOPLAN *840,00", testCats, now)
	if r.CategoryName != "Akaryakıt" {
		t.Fatalf("0PET category = %s", r.CategoryName)
	}
	if r.Amount == nil || *r.Amount != 840 {
		t.Fatalf("TOPLAN amount = %v", r.Amount)
	}
}

func TestShortBrandNotFuzzy(t *testing.T) {
	r := Parse("BIN MARKET\n12.05.2026\nTOPLAM 10,00", testCats, now)
	if r.CategoryName == "Market" {
		t.Fatalf("'bin' must not match brand 'bim' (got %s)", r.CategoryName)
	}
}
