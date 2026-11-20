package receiptparse

// Iptal / iade: market fislerinde bir kalem "** IPTAL **" satiriyle geri alinir. Geri alma satiri
// kalemin ADINI ve ters tutari ("KIVI *-69,22") tasir; OCR bazen eksi isaretini okuyamaz ya da
// tutari bozar ("59,22"). Gercek akis: satis satiri + IPTAL isareti + (miktar satiri) + geri alma
// satiri. Geri alma satiri ne kalem ne de indirimdir: onceki kalemi dusurur.

// isCancelMarker, tutarsiz "IPTAL" / "IADE" isaret satirini tanir ("** IPTAL **", "IPTAL**").
func isCancelMarker(l string) bool {
	if len(amountsIn(l)) > 0 {
		return false
	}
	for _, t := range letterTokens(l) {
		if t == "iptal" || t == "iade" || (len(t) == 5 && levenshtein(t, "iptal") <= 1) {
			return true
		}
	}
	return false
}

// reversalLines, her iptal isaretinden sonraki (en fazla 4 satir icinde) ilk "ad + tutar" satirinin
// indeksini isaretler. Arada kalan yalniz-miktar satirlari ("-0,770 X 89,90 TL") atlanir.
func reversalLines(lines []string) map[int]bool {
	var out map[int]bool
	for i, l := range lines {
		if !isCancelMarker(l) {
			continue
		}
		for j := i + 1; j < len(lines) && j <= i+4; j++ {
			if isTotalLabel(lines[j]) {
				break
			}
			if _, _, ok := nameAndAmount(lines[j]); ok {
				if out == nil {
					out = map[int]bool{}
				}
				out[j] = true
				break
			}
		}
	}
	return out
}

// nameAndAmount, satirin sonundaki tutari ve onun solundaki (temizlenmis) urun adini dondurur; ad en az
// iki harf degilse ok=false (miktar satirlari ve bos etiketler).
func nameAndAmount(l string) (string, float64, bool) {
	masked := maskDates(l)
	m := amountRe.FindAllStringIndex(masked, -1)
	if len(m) == 0 {
		return "", 0, false
	}
	last := m[len(m)-1]
	v, ok := parseAmount(masked[last[0]:last[1]])
	if !ok {
		return "", 0, false
	}
	name := cleanItemName(l[:last[0]])
	if countLetters(name) < 2 {
		return "", 0, false
	}
	return name, v, true
}

// applyReversal, geri alma satirinin iptal ettigi kalemi listeden dusurur: son 4 kalem icinde ayni
// tutarli olan, yoksa (tutar bozuk okunmus olabilir) adi benzeyen SON kalem. Eslesme yoksa dokunmaz
// (mutabakat uyusmazligi bayraklar).
func applyReversal(items []Item, name string, amount float64) []Item {
	drop := -1
	for i := len(items) - 1; i >= 0 && i >= len(items)-4; i-- {
		if approxEq(items[i].Amount, amount) {
			drop = i
			break
		}
	}
	if drop < 0 && len(items) > 0 && similarNames(items[len(items)-1].Name, name) {
		drop = len(items) - 1
	}
	if drop < 0 {
		return items
	}
	return append(append([]Item{}, items[:drop]...), items[drop+1:]...)
}

func similarNames(a, b string) bool {
	fa, fb := FoldTR(a), FoldTR(b)
	if fa == "" || fb == "" {
		return false
	}
	return levenshtein(fa, fb) <= 2 || jaroWinkler(fa, fb) >= 0.7
}
