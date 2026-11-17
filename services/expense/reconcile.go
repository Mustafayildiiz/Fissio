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

// Reconciliation, kalemler toplami ile fis toplaminin mutabakat sonucudur.
type Reconciliation struct {
	Status string `json:"status"` // ok | discount_applied | duplicate_removed | mismatch
	// Diff: (kalemler - indirim) - fis toplami, duzeltmelerden SONRA (0 = tutarli).
	Diff float64 `json:"diff"`
	// SuspectIndex: farki tek basina aciklayan (ama kanit olmadigi icin silinmeyen) kalem.
	SuspectIndex *int   `json:"suspect_index,omitempty"`
	Reason       string `json:"reason,omitempty"`
}

const (
	recOK        = "ok"
	recDiscount  = "discount_applied"
	recDuplicate = "duplicate_removed"
	recMismatch  = "mismatch"
)

type reconcileOutcome struct {
	items       []expenseItem
	needsReview bool
	itemsTotal  *float64
	discount    float64 // kalemlerden dusulecek indirim (0 = yok / kalemlere zaten yansimis)
	info        *Reconciliation
}

// reconcileItems, indirimsiz mutabakatin kisa yoludur.
func reconcileItems(items []expenseItem, total *float64) ([]expenseItem, bool, *float64) {
	o := reconcile(items, total, 0, nil)
	return o.items, o.needsReview, o.itemsTotal
}

// reconcile, kalem fiyatlari toplamini (indirim dusulerek) fis toplamiyla karsilastirir.
//
//   - Fark yoksa bayrak yok (indirim kullanildiysa status=discount_applied).
//   - Kalemler fazla ve fark TEK bir kalemin fiyatina esitse, yalnizca cift okuma kaniti varsa
//     silinir: bitisik, ayni fiyatli, benzer adli kalem ya da adi ozet etiketine benzeyen sizinti.
//     Kanit yoksa silinmez (okunamayan bir kalem ya da indirim yuzunden gercek kalem kaybolmasin),
//     supheli kalem SuspectIndex ile raporlanir.
//   - Kalemler eksikse ve fark atlanan bir etiketli satira ya da tek bir kalemin fiyatina
//     (gozden kacan ikinci adet) esitse gerekce raporlanir; tahminle kalem eklenmez.
//   - Fark kapanmazsa needsReview=true ve hesaplanan kalem toplami doner.
func reconcile(items []expenseItem, total *float64, discount float64, skipped []expenseItem) reconcileOutcome {
	o := reconcileOutcome{items: items, discount: discount}
	if total == nil || len(items) == 0 {
		return o
	}
	sum := sumItems(items)
	if discount > 0 && approxEq(sum, *total) {
		// Indirim satirlari kalem tutarlarina zaten yansitilmis (kalemler net yazilmis).
		o.discount = 0
		o.info = &Reconciliation{Status: recOK, Reason: "discount_already_in_items"}
		return o
	}
	diff := round2(sum - discount - *total)
	if approxEq(diff, 0) {
		status := recOK
		if discount > 0 {
			status = recDiscount
		}
		o.info = &Reconciliation{Status: status}
		return o
	}
	info := &Reconciliation{Status: recMismatch, Diff: diff}
	if diff > 0 {
		if i := duplicateToRemove(items, diff); i >= 0 {
			removed := items[i].Name
			o.items = append(append([]expenseItem{}, items[:i]...), items[i+1:]...)
			o.info = &Reconciliation{Status: recDuplicate, Reason: "removed_duplicate: " + removed}
			return o
		}
		if i := uniqueAmountIndex(items, diff); i >= 0 {
			info.SuspectIndex = &i
			info.Reason = "excess_equals_item"
		}
	} else {
		missing := -diff
		for _, s := range skipped {
			if approxEq(s.Amount, missing) {
				info.Reason = "missing_equals_skipped_line: " + s.Name
				break
			}
		}
		if info.Reason == "" {
			if i := uniqueAmountIndex(items, missing); i >= 0 {
				info.SuspectIndex = &i
				info.Reason = "missing_equals_item"
			}
		}
	}
	o.needsReview, o.itemsTotal, o.info = true, &sum, info
	return o
}

// duplicateToRemove, fiyati diff'e esit ve cift okuma kaniti olan kalemin indeksini dondurur (-1: yok).
func duplicateToRemove(items []expenseItem, diff float64) int {
	for i := range items {
		if !approxEq(items[i].Amount, diff) {
			continue
		}
		if i > 0 && sameItem(items[i], items[i-1]) {
			return i
		}
		if strong, _ := nonItemLabel(items[i].Name); strong {
			return i // ozet satiri kalem olarak sizmis
		}
	}
	return -1
}

// uniqueAmountIndex, fiyati v olan TEK kalemin indeksini dondurur (yoksa ya da birden fazlaysa -1).
func uniqueAmountIndex(items []expenseItem, v float64) int {
	found := -1
	for i, it := range items {
		if approxEq(it.Amount, v) {
			if found >= 0 {
				return -1
			}
			found = i
		}
	}
	return found
}

// resolveTotal, fisin alt blogundaki tutarlardan tutarli bir toplam bulur ve etiket/tutar sutunlari
// OCR'da kaymis olsa bile (egik/kivrik fis) dogru toplami verir:
//   - nakit odemede  odenen - para ustu = toplam   (225,00 - 1,35 = 223,65)
//   - kalemlerin toplami alt blokta bir tutara esitse o tutar toplamdir.
//
// Mevcut toplam zaten tutarliysa degismez. Yalnizca toplam/KDV etiketli ilk satirdan itibaren olan odeme blogu kullanilir.
// ARA TOPLAM ve INDIRIM satirlarinin tutarlari havuza girmez: indirimli fiste kalem toplami ara
// toplama esittir ve dogru (indirimli) toplami ezerdi. Kalem toplami indirim dusulerek karsilastirilir.
func resolveTotal(lines []string, items []expenseItem, discount float64, current *float64) (float64, bool) {
	// Yalnizca toplam/KDV etiketli ilk satirdan itibaren olan odeme blogu: kalem fiyatlari
	// tesadufen odenen-para ustu iliskisini saglayabilir (5,00 + 32,50 = 37,50).
	start := -1
	for i, l := range lines {
		f := foldTR(l)
		if isTotalLabel(l) || isKDVLine(l) || strings.Contains(f, "topk") {
			start = i
			break
		}
	}
	if start < 0 {
		return 0, false
	}
	var pool []float64
	for _, l := range lines[start:] {
		if isSubtotalLine(l) || isDiscountLine(l) {
			continue
		}
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
		sum := round2(sumItems(items) - discount)
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
func recoverBareAmounts(items []expenseItem, cands []bareCandidate, total *float64, discount float64) []expenseItem {
	if total == nil || len(cands) == 0 || len(cands) > 8 {
		return items
	}
	diff := round2(*total + discount - sumItems(items))
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
