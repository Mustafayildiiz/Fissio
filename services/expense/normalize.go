package main

import (
	"strings"
	"unicode"
)

// Bulanik (fuzzy) eslesme esikleri: anahtar kelime uzunluguna gore izin verilen duzenleme mesafesi.
// Kisa kelimelerde ("bim" / "bin", "bp") yanlis pozitifleri onlemek icin yalnizca tam eslesme aranir.
const (
	fuzzyMinLen     = 5 // bu uzunluktan kisa anahtar kelimeler bulanik eslesmez
	fuzzyTwoEditLen = 8 // bu uzunluk ve uzeri: 2 duzenleme, aksi halde 1
)

var ocrDigitFix = map[rune]rune{'0': 'o', '1': 'i', '5': 's', '8': 'b'}

// normalizeOCR, termal fislerde harf yerine okunan rakamlari (0->o, 1->i, 5->s, 8->b) duzeltir.
// Yalnizca TEK rakam iceren ve en az 3 harfli token'lara uygulanir (T0PLAM, MIGR0S, 0PET);
// A101, 500G, 1.250,75, 12.05.2026 gibi tutar/tarih/kod token'larina dokunulmaz.
// Girdi foldTR'den gecmis (kucuk harf, ASCII) metin olmalidir. Yalnizca ESLESTIRME kopyasi
// icin kullanilir; tutar ayristirmaya veya donen isletme adina asla uygulanmaz.
func normalizeOCR(s string) string {
	toks := strings.Fields(s)
	for i, t := range toks {
		toks[i] = fixToken(t)
	}
	return strings.Join(toks, " ")
}

func fixToken(t string) string {
	digits, letters := 0, 0
	for _, r := range t {
		switch {
		case unicode.IsDigit(r):
			digits++
		case unicode.IsLetter(r):
			letters++
		}
	}
	if digits != 1 || letters < 3 {
		return t
	}
	// Token'in geri kalani harf/noktalama olmali (baska rakam yok) ve rakam bilinen bir benzerdir.
	out := []rune(t)
	for i, r := range out {
		if unicode.IsDigit(r) {
			if rep, ok := ocrDigitFix[r]; ok {
				out[i] = rep
			}
		}
	}
	return string(out)
}

func levenshtein(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	if len(ra) == 0 {
		return len(rb)
	}
	if len(rb) == 0 {
		return len(ra)
	}
	prev := make([]int, len(rb)+1)
	cur := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		cur[0] = i
		for j := 1; j <= len(rb); j++ {
			cost := 1
			if ra[i-1] == rb[j-1] {
				cost = 0
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, prev[j-1]+cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(rb)]
}

func maxEdits(kwLen int) int {
	if kwLen >= fuzzyTwoEditLen {
		return 2
	}
	return 1
}

// fuzzyTokenMatch, metindeki bir token'in (cok kelimeli anahtarlarda ardisik token
// birlesiminin) anahtar kelimeye izin verilen duzenleme mesafesi icinde olup olmadigina bakar.
// text ve kw foldTR'den gecmis olmalidir. minLen'den kisa anahtar kelimelerde false doner.
func fuzzyTokenMatch(text, kw string, minLen int) bool {
	if len([]rune(kw)) < minLen {
		return false
	}
	limit := maxEdits(len([]rune(kw)))
	kwToks := strings.Fields(kw)
	toks := strings.Fields(text)
	n := len(kwToks)
	if n == 0 {
		return false
	}
	for i := 0; i+n <= len(toks); i++ {
		if levenshtein(strings.Join(toks[i:i+n], " "), kw) <= limit {
			return true
		}
	}
	return false
}

// hasKeyword, ham satirda anahtar kelimeyi arar. Mevcut alt dize (substring) eslesmesinin YERINE
// degil, ONA EK olarak: duz ya da OCR-duzeltilmis metinde alt dize bulunursa VEYA bulanik
// eslesme varsa true. kw foldTR formunda olmalidir.
func hasKeyword(line, kw string, minFuzzyLen int) bool {
	f := foldTR(line)
	if strings.Contains(f, kw) {
		return true
	}
	n := normalizeOCR(f)
	if strings.Contains(n, kw) {
		return true
	}
	return fuzzyTokenMatch(n, kw, minFuzzyLen)
}

// containsWordFuzzy, containsWord'un (kelime siniri) OCR toleransli hali: once tam kelime
// eslesmesi, sonra OCR-duzeltilmis metinde kelime eslesmesi, son olarak (>= fuzzyMinLen) bulanik.
func containsWordFuzzy(text, word string) bool {
	if containsWord(text, word) {
		return true
	}
	n := normalizeOCR(text)
	if containsWord(n, word) {
		return true
	}
	return fuzzyTokenMatch(n, word, fuzzyMinLen)
}

// hasToken, satirdaki kelimelerden (harf/rakam disi karakterlerle bolunmus) biri tok ise true.
// "TOP *480.00" -> top; "TOPKDV" -> top DEGIL (tam token).
func hasToken(line, tok string) bool {
	f := foldTR(line)
	for _, t := range strings.FieldsFunc(f, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) }) {
		if t == tok {
			return true
		}
	}
	return false
}

// isKDVLine, KDV satirini tanir (OCR sik sik KDV'yi KDU okur).
func isKDVLine(line string) bool {
	if hasKeyword(line, "kdv", fuzzyMinLen) {
		return true
	}
	// OCR KDV'yi KDU/KDY/KOV gibi okur: "k" ile baslayan, "kdv"ye 1 duzenleme uzakta 3 harfli token.
	f := foldTR(line)
	for _, t := range strings.FieldsFunc(f, func(r rune) bool { return !unicode.IsLetter(r) }) {
		if len(t) == 3 && t[0] == 'k' && levenshtein(t, "kdv") <= 1 {
			return true
		}
	}
	return false
}

// isStarBanner, "** ELEKTRIK KESILDI **" gibi yildizla sarilmis bilgi satirlarini tanir.
func isStarBanner(line string) bool {
	t := strings.TrimSpace(line)
	return strings.HasPrefix(t, "**") && strings.HasSuffix(t, "**")
}

// dropLeadingJunk, satir basindaki telefon/numara kalintilarini ("/05445020217 BIRLESIK ...") atar.
func dropLeadingJunk(l string) string {
	toks := strings.Fields(l)
	for len(toks) > 1 {
		digits := 0
		for _, r := range toks[0] {
			if unicode.IsDigit(r) {
				digits++
			}
		}
		if digits >= 4 || strings.HasPrefix(toks[0], "/") {
			toks = toks[1:]
			continue
		}
		break
	}
	return strings.Join(toks, " ")
}
