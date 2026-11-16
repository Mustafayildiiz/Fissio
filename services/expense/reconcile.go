package main

import "math"

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
