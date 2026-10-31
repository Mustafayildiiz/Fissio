package main

import (
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// Category, kategorizasyon motorunun girdisidir (anahtar kelimeler veritabanindan gelir).
type Category struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Keywords []string `json:"keywords,omitempty"`
}

type Confidence struct {
	Amount   float64 `json:"amount"`
	Date     float64 `json:"date"`
	Merchant float64 `json:"merchant"`
	Category float64 `json:"category"`
}

// ParseResult FR-3.1 / FR-3.2 ciktisidir. Bulunamayan alanlar nil'dir.
type ParseResult struct {
	Merchant     string     `json:"merchant"`
	Amount       *float64   `json:"amount"`
	Date         *string    `json:"date"`
	CategoryID   int        `json:"category_id"`
	CategoryName string     `json:"category_name"`
	Confidence   Confidence `json:"confidence"`
	NeedsManual  bool       `json:"needs_manual"`
}

const fallbackCategory = "Diğer"

var (
	trFold = strings.NewReplacer(
		"İ", "i", "I", "i", "ı", "i",
		"Ç", "c", "ç", "c", "Ğ", "g", "ğ", "g",
		"Ö", "o", "ö", "o", "Ş", "s", "ş", "s",
		"Ü", "u", "ü", "u",
	)
	amountRe = regexp.MustCompile(`(?:\d{1,3}(?:\.\d{3})+|\d+)[.,]\d{2}\b`)
	dateRe   = regexp.MustCompile(`\b(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})\b`)
)

// foldTR Turkce karakterleri ASCII'ye indirger ve kucuk harfe cevirir
// (OCR ve buyuk/kucuk harf farklarina tolerans icin).
func foldTR(s string) string {
	return strings.ToLower(trFold.Replace(s))
}

func Parse(text string, cats []Category, now time.Time) ParseResult {
	lines := splitLines(text)
	res := ParseResult{CategoryName: fallbackCategory}

	if v, conf, ok := extractAmount(lines); ok {
		res.Amount = &v
		res.Confidence.Amount = conf
	}
	if d, ok := extractDate(lines, now); ok {
		res.Date = &d
		res.Confidence.Date = 0.9
	}

	header := lines
	if len(header) > 8 {
		header = header[:8]
	}
	res.Merchant, res.Confidence.Merchant = extractMerchant(header, cats)

	id, name, conf := categorize(header, lines, cats)
	res.CategoryID, res.CategoryName, res.Confidence.Category = id, name, conf

	res.NeedsManual = res.Amount == nil
	return res
}

func splitLines(text string) []string {
	var out []string
	for _, l := range strings.Split(strings.ReplaceAll(text, "\r", ""), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			out = append(out, l)
		}
	}
	return out
}

// maskDates tarih parcalarini bosluga cevirir; "12.05.2024" icindeki "12.05" tutar sanilmasin.
func maskDates(s string) string {
	return dateRe.ReplaceAllStringFunc(s, func(m string) string { return strings.Repeat(" ", len(m)) })
}

func amountsIn(line string) []float64 {
	var out []float64
	for _, m := range amountRe.FindAllString(maskDates(line), -1) {
		if v, ok := parseAmount(m); ok {
			out = append(out, v)
		}
	}
	return out
}

// parseAmount "1.250,50", "125,50", "125.50" bicimlerini normalize eder.
func parseAmount(s string) (float64, bool) {
	if len(s) < 4 {
		return 0, false
	}
	intPart := strings.NewReplacer(".", "", ",", "").Replace(s[:len(s)-3])
	v, err := strconv.ParseFloat(intPart+"."+s[len(s)-2:], 64)
	if err != nil {
		return 0, false
	}
	return math.Round(v*100) / 100, true
}

func extractAmount(lines []string) (float64, float64, bool) {
	var tier1, tier2 []int
	for i, l := range lines {
		f := foldTR(l)
		if strings.Contains(f, "kdv") || strings.Contains(f, "%") || strings.Contains(f, "ara toplam") {
			continue
		}
		switch {
		case strings.Contains(f, "toplam") || strings.Contains(f, "odenecek"):
			tier1 = append(tier1, i)
		case strings.Contains(f, "tutar") || strings.Contains(f, "tahsil") ||
			strings.Contains(f, "kredi kart") || strings.Contains(f, "nakit"):
			tier2 = append(tier2, i)
		}
	}
	// Toplam genelde fisin sonuna dogru oldugu icin sondan basla.
	for _, tier := range []struct {
		idx  []int
		conf float64
	}{{tier1, 0.9}, {tier2, 0.6}} {
		for k := len(tier.idx) - 1; k >= 0; k-- {
			i := tier.idx[k]
			if a := amountsIn(lines[i]); len(a) > 0 {
				return a[len(a)-1], tier.conf, true
			}
			// OCR etiketi ve tutari ayri satirlara bolmus olabilir.
			if i+1 < len(lines) {
				if a := amountsIn(lines[i+1]); len(a) > 0 {
					return a[len(a)-1], tier.conf - 0.1, true
				}
			}
		}
	}
	// Son care: KDV/yuzde satirlari disindaki en buyuk tutar.
	best, found := 0.0, false
	for _, l := range lines {
		f := foldTR(l)
		if strings.Contains(f, "kdv") || strings.Contains(f, "%") {
			continue
		}
		for _, a := range amountsIn(l) {
			if a > best {
				best, found = a, true
			}
		}
	}
	return best, 0.3, found
}

func extractDate(lines []string, now time.Time) (string, bool) {
	for _, l := range lines {
		for _, m := range dateRe.FindAllStringSubmatch(l, -1) {
			d, _ := strconv.Atoi(m[1])
			mo, _ := strconv.Atoi(m[2])
			y, _ := strconv.Atoi(m[3])
			if len(m[3]) == 2 {
				y += 2000
			}
			t := time.Date(y, time.Month(mo), d, 0, 0, 0, 0, time.UTC)
			// time.Date tasan gunleri kaydirir (31.02 gibi); gecersizleri ele.
			if t.Day() != d || int(t.Month()) != mo || y < 2000 || t.After(now.AddDate(0, 0, 2)) {
				continue
			}
			return t.Format("2006-01-02"), true
		}
	}
	return "", false
}

var skipMerchantWords = []string{"fis", "tarih", "saat", "vkn", "vergi", "tel", "adres", "mersis", "no:", "www", "http", "kasiyer", "sicil"}

func extractMerchant(header []string, cats []Category) (string, float64) {
	// Bilinen bir marka anahtar kelimesi iceren ilk satir en guvenilir adaydir.
	for _, l := range header {
		f := foldTR(l)
		for _, c := range cats {
			for _, kw := range c.Keywords {
				if containsWord(f, foldTR(kw)) {
					return cleanMerchant(l), 0.8
				}
			}
		}
	}
	for _, l := range header {
		f := foldTR(l)
		skip := false
		for _, w := range skipMerchantWords {
			if strings.Contains(f, w) {
				skip = true
				break
			}
		}
		letters, digits := 0, 0
		for _, r := range l {
			if unicode.IsLetter(r) {
				letters++
			} else if unicode.IsDigit(r) {
				digits++
			}
		}
		if !skip && letters >= 3 && digits <= letters {
			return cleanMerchant(l), 0.5
		}
	}
	return "", 0
}

func cleanMerchant(l string) string {
	l = strings.TrimSpace(strings.Trim(l, "*-=_# "))
	if r := []rune(l); len(r) > 60 {
		l = string(r[:60])
	}
	return l
}

func categorize(header, all []string, cats []Category) (int, string, float64) {
	headerText := foldTR(strings.Join(header, "\n"))
	allText := foldTR(strings.Join(all, "\n"))

	bestID, bestName, bestScore := 0, fallbackCategory, 0
	for _, c := range cats {
		if c.Name == fallbackCategory {
			bestID = c.ID
		}
		score := 0
		for _, kw := range c.Keywords {
			k := foldTR(kw)
			if containsWord(headerText, k) {
				score += 3 // Baslikta gecen marka daha guclu sinyaldir.
			}
			if containsWord(allText, k) {
				score++
			}
		}
		if score > bestScore {
			bestID, bestName, bestScore = c.ID, c.Name, score
		}
	}
	switch {
	case bestScore >= 3:
		return bestID, bestName, 0.9
	case bestScore > 0:
		return bestID, bestName, 0.6
	default:
		return bestID, bestName, 0
	}
}

// containsWord kelime sinirina saygi ile arar ("bp", "abpx" icinde eslesmesin).
func containsWord(text, word string) bool {
	if word == "" {
		return false
	}
	for from := 0; ; {
		i := strings.Index(text[from:], word)
		if i < 0 {
			return false
		}
		i += from
		end := i + len(word)
		beforeOK := i == 0 || !isAlnum(rune(text[i-1]))
		afterOK := end == len(text) || !isAlnum(rune(text[end]))
		if beforeOK && afterOK {
			return true
		}
		from = i + 1
	}
}

func isAlnum(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
}

