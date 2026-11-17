package main

import (
	"regexp"
	"strings"
	"unicode"
)

// Fisin ozet/bilgi satirlari (TOPLAM, ARA TOPLAM, KDV, INDIRIM, NAKIT, KREDI KARTI, PARA USTU...)
// asla kalem olmaz; toplam dogrulamasi icin ReceiptSummary metadata'sina ayrilir.

// ReceiptSummary, fisin alt blogundan okunan dogrulama metadata'sidir (kalem degildir).
type ReceiptSummary struct {
	Subtotal  *float64  `json:"subtotal,omitempty"`
	Discounts []float64 `json:"discounts,omitempty"`
	VATTotal  *float64  `json:"vat_total,omitempty"`
	PaidCash  *float64  `json:"paid_cash,omitempty"`
	PaidCard  *float64  `json:"paid_card,omitempty"`
	Change    *float64  `json:"change,omitempty"`
}

func (s ReceiptSummary) empty() bool {
	return s.Subtotal == nil && len(s.Discounts) == 0 && s.VATTotal == nil &&
		s.PaidCash == nil && s.PaidCard == nil && s.Change == nil
}

// Eksi isaretli tutar ("-5,00", "* -12,50"): urun satirlari negatif olmaz, indirim/iadedir.
var negativeAmountRe = regexp.MustCompile(`(?:^|[\s*:])-\s*(?:\d{1,3}(?:\.\d{3})+|\d+)[.,]\d{2}\b`)

// Uzun (cok harfli) etiketler: alt dize, bosluksuz alt dize (OCR'in yapistirdigi "PARAUSTU",
// "KREDIKARTI") ve >= 6 harfte bulanik eslesme. Urun adlarinda gecmeyecek kadar ayirt edicidir.
var strongNonItemLabels = []string{
	"toplam", "topkdv", "odenecek", "para ustu", "fis no", "mersis", "tesekkur",
	"kredi kart", "banka kart", "provizyon", "nakit",
}

// Kisa etiketler YALNIZCA tam kelime (harf dizisi) olarak eslesir: "kart" KARTON SUT'u,
// "onay" / "saat" / "banka" gercek urunleri dusurmesin.
var weakNonItemTokens = map[string]bool{
	"tutar": true, "tutari": true, "kredi": true, "kart": true, "karti": true,
	"tarih": true, "tarihi": true, "saat": true, "vkn": true, "vergi": true,
	"banka": true, "bankasi": true, "onay": true, "onayi": true,
}

// hasPhrase, bosluksuz yazilmis etiketi KELIME BASINDAN baslayarak arar: OCR'in yapistirdigi
// "ARATOPLAM", "PARAUSTU", "KREDIKARTI" eslesir; kelime ortasindan baslayan "KARA TOPRAK"
// ("aratop") eslesmez.
func hasPhrase(line, needle string) bool {
	toks := letterTokens(line)
	for i := range toks {
		if strings.HasPrefix(strings.Join(toks[i:], ""), needle) {
			return true
		}
	}
	return false
}

// letterTokens, satiri yalnizca harf dizilerine boler ("TARIH12.12.2019" -> [tarih]).
func letterTokens(line string) []string {
	return strings.FieldsFunc(normalizeOCR(foldTR(line)), func(r rune) bool { return !unicode.IsLetter(r) })
}

func hasLetterToken(line string, toks ...string) bool {
	for _, t := range letterTokens(line) {
		for _, w := range toks {
			if t == w {
				return true
			}
		}
	}
	return false
}

func isSubtotalLine(l string) bool {
	return hasPhrase(l, "aratop") || fuzzyTokenMatch(normalizeOCR(foldTR(l)), "ara toplam", fuzzyMinLen)
}

// discountTokens: indirim satirinin etiket kelimeleri. "INDIRIMLI FIYAT" gibi urun/aciklama
// satirlari (pozitif tutarli) indirim sayilmaz; yalnizca tam kelime, 1 harflik OCR hatasi
// ya da eksi isaretli tutar.
var discountTokens = []string{"indirim", "indirimi", "iskonto", "iskontosu"}

func isDiscountLine(l string) bool {
	if negativeAmountRe.MatchString(maskDates(l)) {
		return true
	}
	for _, t := range letterTokens(l) {
		for _, d := range discountTokens {
			if t == d || (len(t) == len(d) && levenshtein(t, d) <= 1) {
				return true
			}
		}
	}
	return false
}

// isTotalLabel, genel toplam satirini tanir (ARA TOPLAM ve TOPLAM INDIRIM haric).
func isTotalLabel(l string) bool {
	return (hasKeyword(l, "toplam", fuzzyMinLen) || hasToken(l, "top")) && !isSubtotalLine(l) && !isDiscountLine(l)
}

// nonItemLabel, satirin ozet/bilgi satiri olup olmadigini soyler. strong: kesin etiket;
// weak: yalnizca kisa bir kelime eslesti (gercek urun olma ihtimali dusuk ama sifir degil;
// mutabakatta "atlanan satir" adayi olarak raporlanir).
func nonItemLabel(l string) (strong, weak bool) {
	if isKDVLine(l) || isSubtotalLine(l) || isDiscountLine(l) {
		return true, false
	}
	for _, kw := range strongNonItemLabels {
		if hasKeyword(l, kw, 6) || hasPhrase(l, strings.ReplaceAll(kw, " ", "")) {
			return true, false
		}
	}
	for _, t := range letterTokens(l) {
		if weakNonItemTokens[t] {
			return false, true
		}
	}
	return false, false
}

// itemRegionEnd, kalem bolgesinin bittigi (genel toplam etiketli ilk) satirin indeksidir.
func itemRegionEnd(lines []string) int {
	for i, l := range lines {
		if isTotalLabel(l) {
			return i
		}
	}
	return len(lines)
}

// extractSummary, ozet satirlarini metadata'ya ayirir ve kalemlerden dusulecek indirim toplamini
// dondurur. Indirimler yalnizca kalem bolgesinden (genel toplamdan once) alinir; toplamdan sonraki
// "TOPLAM INDIRIM / KAZANCINIZ" satirlari zaten uygulanmis indirimlerin ozetidir. Tek tek indirim
// satiri varsa "TOPLAM INDIRIM" ozeti cift sayilmasin diye yok sayilir.
func extractSummary(lines []string) (ReceiptSummary, float64) {
	var s ReceiptSummary
	end := itemRegionEnd(lines)
	var individual, recap []float64
	last := func(l string) (float64, bool) {
		a := amountsIn(l)
		if len(a) == 0 {
			return 0, false
		}
		return a[len(a)-1], true
	}
	for i, l := range lines {
		v, ok := last(l)
		if !ok {
			continue
		}
		switch {
		case isDiscountLine(l):
			if i >= end {
				continue
			}
			if hasKeyword(l, "toplam", fuzzyMinLen) {
				recap = append(recap, v)
			} else {
				individual = append(individual, v)
			}
		case isSubtotalLine(l):
			s.Subtotal = ptr(v)
		case isKDVLine(l) && (hasPhrase(l, "topkdv") || hasKeyword(l, "toplam", fuzzyMinLen)):
			s.VATTotal = ptr(v)
		case hasPhrase(l, "paraustu"):
			s.Change = ptr(v)
		case hasKeyword(l, "nakit", fuzzyMinLen):
			s.PaidCash = ptr(v)
		case hasPhrase(l, "kredikart") || hasPhrase(l, "bankakart") || hasLetterToken(l, "kart", "karti"):
			s.PaidCard = ptr(v)
		}
	}
	s.Discounts = individual
	if len(s.Discounts) == 0 {
		s.Discounts = recap
	}
	total := 0.0
	for _, d := range s.Discounts {
		total += d
	}
	return s, round2(total)
}

func ptr(v float64) *float64 { return &v }
