package main

import (
	"math"
	"strings"
	"unicode"
)

func round2(v float64) float64 { return math.Round(v*100) / 100 }

func sumItems(items []expenseItem) float64 {
	s := 0.0
	for _, it := range items {
		s += it.Amount
	}
	return round2(s)
}

// sameItem, iki kalemin ayni urunun cift okunmasi olup olmadigini soyler: ayni fiyat ve
// (OCR hatasina tolerans icin) ayni/benzer ad.
func sameItem(a, b expenseItem) bool {
	if math.Abs(a.Amount-b.Amount) >= 0.005 {
		return false
	}
	na, nb := foldTR(a.Name), foldTR(b.Name)
	if na == nb {
		return true
	}
	limit := len([]rune(na)) / 5
	if limit < 1 {
		limit = 1
	}
	return levenshtein(na, nb) <= limit
}

// reconcileItems, kalem fiyatlari toplamini fis toplamiyla karsilastirir.
//
//   - Fark yoksa (veya karsilastirilacak kalem/toplam yoksa) bayrak yok.
//   - Kalemler fazla ve fark bir kalemin fiyatina esitse, YALNIZCA bitisik, ayni fiyatli ve benzer
//     adli (cift okuma kaniti olan) kalem silinir. Kanit yoksa silinmez; okunamayan bir kalem
//     ya da indirim satiri yuzunden gercek bir kalem sessizce kaybolmasin.
//   - Fark kapanmazsa needsReview=true ve hesaplanan kalem toplami doner.
func reconcileItems(items []expenseItem, total *float64) (out []expenseItem, needsReview bool, itemsTotal *float64) {
	if total == nil || len(items) == 0 {
		return items, false, nil
	}
	sum := sumItems(items)
	diff := round2(sum - *total)
	if math.Abs(diff) < 0.005 {
		return items, false, nil
	}
	if diff > 0 {
		for i := 1; i < len(items); i++ {
			if math.Abs(items[i].Amount-diff) < 0.005 && sameItem(items[i], items[i-1]) {
				cleaned := append(append([]expenseItem{}, items[:i]...), items[i+1:]...)
				newSum := sumItems(cleaned)
				if math.Abs(round2(newSum-*total)) < 0.005 {
					return cleaned, false, nil
				}
				items, sum = cleaned, newSum
				break
			}
		}
	}
	return items, true, &sum
}

// resolveTotal, fisin alt blogundaki tutarlardan tutarli bir toplam bulur ve etiket/tutar sutunlari
// OCR'da kaymis olsa bile (egik/kivrik fis) dogru toplami verir:
//   - nakit odemede  odenen - para ustu = toplam   (225,00 - 1,35 = 223,65)
//   - kalemlerin toplami alt blokta bir tutara esitse o tutar toplamdir.
//
// Mevcut toplam zaten tutarliysa degismez. Yalnizca toplam/KDV etiketli ilk satirdan itibaren olan odeme blogu kullanilir.
func resolveTotal(lines []string, items []expenseItem, current *float64) (float64, bool) {
	// Yalnizca toplam/KDV etiketli ilk satirdan itibaren olan odeme blogu: kalem fiyatlari
	// tesadufen odenen-para ustu iliskisini saglayabilir (5,00 + 32,50 = 37,50).
	start := -1
	for i, l := range lines {
		f := foldTR(l)
		if hasKeyword(l, "toplam", fuzzyMinLen) || hasToken(l, "top") || isKDVLine(l) || strings.Contains(f, "topk") {
			start = i
			break
		}
	}
	if start < 0 {
		return 0, false
	}
	var pool []float64
	for _, l := range lines[start:] {
		pool = append(pool, amountsIn(l)...)
	}
	has := func(v float64) bool {
		for _, a := range pool {
			if math.Abs(a-v) < 0.005 {
				return true
			}
		}
		return false
	}
	same := func(v float64) bool { return current != nil && math.Abs(*current-v) < 0.005 }

	// 1) Kalem toplami alt blokta bir tutara esit
	if len(items) >= 2 {
		sum := sumItems(items)
		if has(sum) && !same(sum) {
			return sum, true
		}
	}
	// 2) odenen - para ustu = toplam
	best, found := 0.0, false
	for _, paid := range pool {
		for _, change := range pool {
			total := round2(paid - change)
			if change <= 0 || total <= change || !has(total) || math.Abs(total-paid) < 0.005 {
				continue
			}
			if same(total) {
				return 0, false // mevcut toplam zaten tutarli
			}
			if total > best {
				best, found = total, true
			}
		}
	}
	return best, found
}

// bareCandidate, tutari ondalik ayiraci olmadan okunmus bir satirdir ("*070" -> 0,70).
// Pos, aday ortaya ciktiginda o ana kadar toplanan kalem sayisidir (ekleme konumu).
type bareCandidate struct {
	Pos  int
	Item expenseItem
}

func countLetters(s string) int {
	n := 0
	for _, r := range s {
		if unicode.IsLetter(r) {
			n++
		}
	}
	return n
}

// recoverBareAmounts, kalem toplami fis toplaminin altindaysa ve eksik fark TAM OLARAK bir aday
// alt kumesinin toplamina esitse (en fazla 8 aday), o kalemleri yerlerine ekler. Fark kapanmiyorsa
// hicbir sey eklenmez (tahmini tutarlarla kalem uydurulmaz).
func recoverBareAmounts(items []expenseItem, cands []bareCandidate, total *float64) []expenseItem {
	if total == nil || len(cands) == 0 || len(cands) > 8 {
		return items
	}
	diff := round2(*total - sumItems(items))
	if diff <= 0.005 {
		return items
	}
	var picked []int
	for mask := 1; mask < 1<<len(cands); mask++ {
		sum := 0.0
		for i := range cands {
			if mask&(1<<i) != 0 {
				sum += cands[i].Item.Amount
			}
		}
		if math.Abs(round2(sum)-diff) < 0.005 {
			picked = picked[:0]
			for i := range cands {
				if mask&(1<<i) != 0 {
					picked = append(picked, i)
				}
			}
			break
		}
	}
	if len(picked) == 0 {
		return items
	}
	out := make([]expenseItem, 0, len(items)+len(picked))
	pi := 0
	for idx := 0; idx <= len(items); idx++ {
		for pi < len(picked) && cands[picked[pi]].Pos == idx {
			out = append(out, cands[picked[pi]].Item)
			pi++
		}
		if idx < len(items) {
			out = append(out, items[idx])
		}
	}
	return out
}
