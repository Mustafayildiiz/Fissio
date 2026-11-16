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
