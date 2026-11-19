package receiptparse

import (
	"math"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Ortak altin vektorler (`testdata/parse/*.json`): ayni dosyalari Dart cihaz-ici ayristiricisi
// (`fissio_mobile/test/golden_parse_test.dart`) dogrular; iki kopyanin para sonuclari ayni kalmali.
// Kategoriler uretimdeki gibi bos keywords'lu seed adlaridir: enrichCats tum sozluk markalarini ekler
// (isletme satiri secimi bunlara baglidir; testCats yalnizca Market/Akaryakit markalarini getirirdi).

type goldenParse struct {
	Name   string `json:"name"`
	Text   string `json:"text"`
	Expect struct {
		Merchant      string   `json:"merchant"`
		Amount        *float64 `json:"amount"`
		Date          *string  `json:"date"`
		ItemCount     int      `json:"item_count"`
		NeedsReview   bool     `json:"needs_review"`
		DiscountTotal float64  `json:"discount_total"`
		Items         []struct {
			Name   string  `json:"name"`
			Amount float64 `json:"amount"`
		} `json:"items"`
	} `json:"expect"`
	KnownDivergence []string `json:"known_divergence"`
}

func goldenCats() []Category {
	seed := []string{"Market / Gıda", "Restoran / Kafe", "Akaryakıt / Ulaşım", "Giyim", "Elektronik",
		"Sağlık / Eczane", "Fatura / Abonelik", "Ev / Yaşam", "Kişisel Bakım", "Eğlence / Hobi", "Diğer"}
	cats := make([]Category, len(seed))
	for i, n := range seed {
		cats[i] = Category{ID: i + 1, Name: n}
	}
	return cats
}

func cents(v float64) int64 { return int64(math.Round(v * 100)) }

func TestGoldenParse(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("..", "..", "..", "..", "testdata", "parse", "*.json"))
	if err != nil || len(files) < 8 {
		t.Fatalf("testdata/parse vektorleri eksik: %d (%v)", len(files), err)
	}
	for _, f := range files {
		var g goldenParse
		loadTestdata(t, filepath.Join("parse", filepath.Base(f)), &g)
		t.Run(g.Name, func(t *testing.T) {
			e := g.Expect
			r := Parse(g.Text, goldenCats(), now)
			if r.Merchant != e.Merchant {
				t.Errorf("merchant = %q, want %q", r.Merchant, e.Merchant)
			}
			if (r.Amount == nil) != (e.Amount == nil) || (r.Amount != nil && cents(*r.Amount) != cents(*e.Amount)) {
				t.Errorf("amount = %v, want %v", r.Amount, e.Amount)
			}
			if (r.Date == nil) != (e.Date == nil) || (r.Date != nil && *r.Date != *e.Date) {
				t.Errorf("date = %v, want %v", r.Date, e.Date)
			}
			if r.NeedsReview != e.NeedsReview {
				t.Errorf("needs_review = %v, want %v", r.NeedsReview, e.NeedsReview)
			}
			disc := 0.0
			if r.DiscountTotal != nil {
				disc = *r.DiscountTotal
			}
			if cents(disc) != cents(e.DiscountTotal) {
				t.Errorf("discount_total = %v, want %v", disc, e.DiscountTotal)
			}
			if len(r.Items) != e.ItemCount || len(r.Items) != len(e.Items) {
				t.Fatalf("items = %d, want %d (%v)", len(r.Items), e.ItemCount, r.Items)
			}
			for i, it := range r.Items {
				if it.Name != e.Items[i].Name || cents(it.Amount) != cents(e.Items[i].Amount) {
					t.Errorf("item[%d] = %q %v, want %q %v", i, it.Name, it.Amount, e.Items[i].Name, e.Items[i].Amount)
				}
			}
		})
	}
}

// TestMerchantBrandsMatchLexicon: Dart `merchantBrands` (brands.dart) ile ayni olmasi gereken liste
// `testdata/merchant_brands.json`'dadir; sozluge marka eklenince bu test kirilir, JSON ve Dart listesi
// birlikte guncellenir.
func TestMerchantBrandsMatchLexicon(t *testing.T) {
	var data struct {
		Brands []string `json:"brands"`
	}
	loadTestdata(t, "merchant_brands.json", &data)
	seen := map[string]bool{}
	var got []string
	for _, c := range enrichCats(goldenCats()) {
		for _, kw := range c.Keywords {
			if f := FoldTR(kw); !seen[f] {
				seen[f] = true
				got = append(got, f)
			}
		}
	}
	sort.Strings(got)
	want := append([]string{}, data.Brands...)
	sort.Strings(want)
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("merchant_brands.json sozlukle uyusmuyor:\n got  %v\n want %v", got, want)
	}
}
