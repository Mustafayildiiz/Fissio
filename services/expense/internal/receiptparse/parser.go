// Package receiptparse, fis metninden yapisal alanlari cikaran saf (DB'siz) hattir: satir/glif
// normalizasyonu, tutar/tarih/isletme, ozet satirlari, kalemler, mutabakat ve otomatik kategorilendirme.
// Kullanici kurallari RuleSet olarak disaridan verilir; okuma/yazma package main'dedir (rules.go).
package receiptparse

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

// Item hem ayristirma ciktisinin hem istegin hem de JSONB'nin kalem tipidir (package main'de expenseItem
// takma adiyla kullanilir). Kategori alanlari opsiyoneldir (eski satirlar sifir degerle okunur). Yalnizca
// {name, amount, category_id} saklanir (bkz. main.itemsForStorage); guven/kaynak/inceleme alanlari
// ayristirma ciktisina, suggested_category_id yalnizca istege aittir (kullanici duzeltmesinden kural
// ogrenmek icin).
type Item struct {
	Name               string  `json:"name"`
	Amount             float64 `json:"amount"`
	CategoryID         int     `json:"category_id,omitempty"`
	CategoryName       string  `json:"category_name,omitempty"`
	CategoryConfidence float64 `json:"category_confidence,omitempty"`
	CategorySource     string  `json:"category_source,omitempty"`
	CategoryReview     bool    `json:"category_review,omitempty"`

	SuggestedCategoryID int `json:"suggested_category_id,omitempty"`
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
	Items        []Item     `json:"items,omitempty"`
	Confidence   Confidence `json:"confidence"`
	NeedsManual  bool       `json:"needs_manual"`
	// NeedsReview: kalemlerin toplami fis toplamiyla tutmuyor; ItemsTotal hesaplanan kalem toplamidir.
	NeedsReview bool     `json:"needs_review"`
	ItemsTotal  *float64 `json:"items_total,omitempty"`
	// DiscountTotal: kalem toplamindan dusulmesi gereken indirim (kalemler - indirim = fis toplami).
	// Istemci kaydedilen tutari buna gore hesaplar. Indirim yoksa ya da kalemlere zaten
	// yansitilmissa alan yoktur.
	DiscountTotal  *float64        `json:"discount_total,omitempty"`
	Summary        *ReceiptSummary `json:"summary,omitempty"`
	Reconciliation *Reconciliation `json:"reconciliation,omitempty"`
	// Otomatik kategorilendirme (bkz. categorizer.go). CategoryNeedsReview, NeedsReview'dan (toplam
	// uyusmazligi) AYRIDIR: kategori guveni dusuk / "Diğer"e dusuldu, kullanici kontrol etmeli.
	CategorySource      string              `json:"category_source,omitempty"`
	CategoryNeedsReview bool                `json:"category_needs_review"`
	CategoryCandidates  []CategoryCandidate `json:"category_candidates,omitempty"`
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
	// Etiketle yapisik yazilan tarihler de (TARIH12.12.2019) yakalansin: \b yerine rakam-olmayan sinir.
	// Saat tarihe bosluksuz yapisik olabilir ("18/10/202617:06"): yilin ardindan SS:DD de kabul edilir.
	dateRe = regexp.MustCompile(`(?:^|\D)(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})(?:\D|$|\d{2}:\d{2})`)
	// Tutara yapisik para birimi: "5.00t" (TL simgesi OCR'da t), "24,90TL", "5,00₺" -> "5.00" / "24,90".
	currencySuffixRe = regexp.MustCompile(`(\d[.,]\d{2})(?:TL|tl|[tT₺])\b`)
	// Satir SONUNDA ondaliksiz tutar + acik para birimi: "355TRY", "665 TRY", "-310 TRY", "1.250 TL" -> "355,00" ...
	// (dijital fis/e-posta tablolari). Satir sonu sarti "10 TL indirim kuponu" gibi aciklamalari bozmaz; ondalikli
	// bicimler currencySuffixRe'nin isidir. Grup 1 = onceki karakter (rakam/nokta/virgul OLAMAZ), grup 2 = tutar.
	intCurrencyRe = regexp.MustCompile(`(?i)(^|[^\d.,])(-?(?:\d{1,3}(?:\.\d{3})+|\d+))\s?(?:TRY|TL|₺)\s*$`)
	// Urun satiri izi: KDV orani sutunu (%08, x08) ya da satir sonunda tutar; baslik/isletme adi olamaz.
	itemRowRe = regexp.MustCompile(`%\s*\d{1,2}|(?:^|\s)[xX]\d{2}\b|\d[.,]\d{2}\s*[*tT₺]?\s*$`)
	// OCR ondalik ayiraci sonrasina bosluk koyabilir ("+24, 90" -> "24,90").
	spacedDecimalRe = regexp.MustCompile(`(\d[.,])\s(\d{2})\b`)
	// Adet/miktar satiri: "4Adt X 0,90", "3 X 1,00", "4AdtX0.90", OCR bozugu "3A0.25",
	// "2 ADET X 15,00 = 30,00", "0,535 KG X 89,90". Grup 1 = miktar, grup 2 = birim fiyat.
	// BIM'de kalemden ONCE, bircok fiste ad satirinin ALTINDA gelir. Birimli (KG/GR/LT) ve "*"
	// bicimlerinde carpi isareti zorunludur ("1L SUT", "08 *3,95" adet satiri sanilmasin).
	// Sol kenari kirpilmis fislerde miktar rakami dusebilir ("ADET X 13,50 TL"): sayi yalniz "adet/adt + x"
	// biciminde istege baglidir (grup 1 bos kalir, miktar bilinmez).
	qtyPrefixRe = regexp.MustCompile(`(?i)^\s*(?:(\d+(?:[.,]\d{1,3})?)\s*(?:(?:adet|adt|ad|ag|a)\.?\s*[x×*]?|(?:kg|kq|k9|gr|g|lt|l)\.?\s*[x×*]|[x×])|(?:adet|adt)\.?\s*[x×*])\s*((?:\d{1,3}(?:\.\d{3})+|\d+)[.,]\d{2})`)
	// Kalem adi sonundaki KDV orani ve sutun kalintilari (%08, 08, 808, 80%, %18, *).
	trailingXRe = regexp.MustCompile(`(?i)\s+x$`)
	// Ondalik ayiraci dusmus tutar: "%08 *070" -> 0,70; "%08 100" -> 1,00 (satirsonu, 3-4 hane).
	bareAmountRe = regexp.MustCompile(`[\s*+$x](\d{3,4})\s*$`)
	itemTailRe   = regexp.MustCompile(`(?i)(?:[\s*+$]+(?:%\s*\d{1,2}|\d{1,2}\s*%|[48]?08|01|10|18|20|1|8))+[\s*+$]*$`)
)

// FoldTR Turkce karakterleri ASCII'ye indirger ve kucuk harfe cevirir
// (OCR ve buyuk/kucuk harf farklarina tolerans icin).
func FoldTR(s string) string {
	return strings.ToLower(trFold.Replace(s))
}

func Parse(text string, cats []Category, now time.Time) ParseResult {
	return ParseWith(text, cats, now, ParseOptions{})
}

// ParseWith, Parse'in kullanici kurallari gibi istege bagli girdi alan halidir.
func ParseWith(text string, cats []Category, now time.Time, opts ParseOptions) ParseResult {
	cats = enrichCats(cats)
	ci := newCatIndex(cats)
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

	m := ci.classifyMerchant(cats, header, lines, res.Merchant, opts.Rules)
	res.CategoryID, res.CategoryName, res.Confidence.Category = m.ID, m.Name, m.Conf

	summary, discount := extractSummary(lines)
	if !summary.empty() {
		res.Summary = &summary
	}

	var bare []bareCandidate
	var skipped []Item
	res.Items, bare, skipped = extractItemsWithBare(lines, res.Amount)
	if t, ok := resolveTotal(lines, res.Items, discount, res.Amount); ok {
		res.Amount = &t
		res.Confidence.Amount = 0.85
	}
	res.Items = recoverBareAmounts(res.Items, bare, res.Amount, discount)
	o := reconcile(res.Items, res.Amount, discount, skipped)
	if o.needsReview && res.Amount != nil && vatExcludedItems(lines, o.items, o.discount, *res.Amount) {
		// E-fatura: kalem tutarlari KDV'siz; toplam = kalemler + KDV ve "Odenecek Tutar" etiketli. Uyusmazlik degil.
		o.needsReview, o.itemsTotal, o.info = false, nil, &Reconciliation{Status: recOK, Reason: "items_exclude_vat"}
	}
	res.Items, res.NeedsReview, res.ItemsTotal, res.Reconciliation = o.items, o.needsReview, o.itemsTotal, o.info
	if o.discount > 0 {
		res.DiscountTotal = ptr(o.discount)
	}
	res.NeedsManual = res.Amount == nil
	// Kalemler nihai olduktan sonra: kalem kategorileri + fis kategorisi (isletme / oylama / fallback).
	ci.applyCategories(&res, m, opts.Rules)
	return res
}

// splitLines, metni bos olmayan satirlara boler; ondalik bosluklarini ve OCR glif hatalarini
// (`$` -> S-cedilla, bkz. fixTurkishGlyphs) duzeltir. Parse ve MergePageTexts'in tek girisidir.
func splitLines(text string) []string {
	var out []string
	for _, l := range strings.Split(strings.ReplaceAll(text, "\r", ""), "\n") {
		l = currencySuffixRe.ReplaceAllString(spacedDecimalRe.ReplaceAllString(l, "$1$2"), "$1")
		l = intCurrencyRe.ReplaceAllString(l, "${1}${2},00")
		if l = strings.TrimSpace(fixTurkishGlyphs(l)); l != "" {
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
		f := FoldTR(l)
		if isKDVLine(l) || strings.Contains(f, "%") || isSubtotalLine(l) || isDiscountLine(l) {
			continue
		}
		switch {
		case hasKeyword(l, "toplam", fuzzyMinLen) || hasKeyword(l, "odenecek", fuzzyMinLen) || hasToken(l, "top"):
			tier1 = append(tier1, i)
		case hasKeyword(l, "tutar", fuzzyMinLen) || hasKeyword(l, "tahsil", fuzzyMinLen) ||
			hasKeyword(l, "kredi kart", fuzzyMinLen) || hasKeyword(l, "nakit", fuzzyMinLen):
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
			// Uygulama fislerinde (Toplam:) tutar etiketin ustune yerlesebilir: yalnizca tutardan
			// olusan onceki satir da etiketin degeridir.
			if i > 0 && isAmountOnlyLine(lines[i-1]) {
				if a := amountsIn(lines[i-1]); len(a) == 1 {
					return a[0], tier.conf - 0.2, true
				}
			}
			// Sutunlar yer degistirmis: KDV satiri hem KDV'yi hem toplami tasir ("TOPKDV 307.85 22,79" + bos
			// "TOPLAM"). KDV toplamdan cok kucuktur (en fazla ~%20): buyuk tutar toplamdir.
			if i > 0 && isKDVLine(lines[i-1]) {
				if hi, _, ok := vatAndTotal(amountsIn(lines[i-1])); ok {
					return hi, tier.conf - 0.2, true
				}
			}
		}
	}
	// Son care: KDV/yuzde satirlari disindaki en buyuk tutar.
	best, found := 0.0, false
	for _, l := range lines {
		f := FoldTR(l)
		if isKDVLine(l) || strings.Contains(f, "%") {
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

// vatAndTotal, iki tutardan buyugu (toplam) ve kucugu (KDV) dondurur; buyuk >= 5 x kucuk degilse ok=false.
func vatAndTotal(a []float64) (hi, lo float64, ok bool) {
	if len(a) != 2 {
		return 0, 0, false
	}
	hi, lo = math.Max(a[0], a[1]), math.Min(a[0], a[1])
	return hi, lo, lo > 0 && hi >= lo*5
}

// isAmountOnlyLine, satirin yalnizca bir tutardan (ve "*", "TL" gibi sutun isaretlerinden) olustugunu soyler.
func isAmountOnlyLine(l string) bool {
	m := amountRe.FindAllStringIndex(l, -1)
	if len(m) != 1 {
		return false
	}
	rest := l[:m[0][0]] + l[m[0][1]:]
	return strings.Trim(rest, " *+$=:-") == ""
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

var skipMerchantWords = []string{"elektrik", "kesildi", "eku", "fis", "tarih", "saat", "vkn", "vergi", "tel", "adres", "mersis", "no:", "www", "http", "kasiyer", "sicil"}

func extractMerchant(header []string, cats []Category) (string, float64) {
	// Bilinen bir marka anahtar kelimesi iceren ilk satir en guvenilir adaydir.
	for _, l := range header {
		if itemRowRe.MatchString(l) {
			continue // urun satiri ("KASAR PEYNIR %01 *139,90") marka eslesmesinden de dislanir
		}
		f := FoldTR(l)
		for _, c := range cats {
			for _, kw := range c.Keywords {
				if containsWordFuzzy(f, FoldTR(kw)) {
					return cleanMerchant(l), 0.8
				}
			}
		}
	}
	for _, l := range header {
		f := FoldTR(l)
		skip := false
		for _, w := range skipMerchantWords {
			if strings.Contains(f, w) {
				skip = true
				break
			}
		}
		if isStarBanner(l) {
			continue // "** ELEKTRIK KESILDI **" gibi bilgi satirlari isletme adi degildir
		}
		if itemRowRe.MatchString(l) {
			break // baslik bitti (kirpilmis fiste ilk urun satiri): sonraki satirlar isletme adi olamaz
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
	l = dropLeadingJunk(l)
	if r := []rune(l); len(r) > 60 {
		l = string(r[:60])
	}
	return l
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

func extractItems(lines []string, totalAmount *float64) []Item {
	items, _, _ := extractItemsWithBare(lines, totalAmount)
	return items
}

func approxEq(a, b float64) bool { return math.Abs(a-b) < 0.005 }

// applyQtyLine, net satir tutari tasiyan bir adet satirini ("2 ADET X 15,00 = 30,00") isler.
// Net tutar satirin EN SAGINDAKI tutardir: OCR servisi satir bloklarini x_min'e gore soldan saga
// dizer, dolayisiyla metindeki son tutar en buyuk X'li tutardir. Birim fiyat asla ayri kalem olmaz.
//   - Ustteki satir yalnizca ad tasiyorsa (pending): ad + net tutar = tek kalem.
//   - Onceki kalem zaten net tutardaysa satir bilgi satiridir.
//   - Onceki kalem birim fiyatla yazilmissa ve miktar x birim = net ise kalem net tutara cekilir.
func applyQtyLine(items []Item, pending string, qty, unit, net float64) []Item {
	switch {
	case pending != "":
		return append(items, Item{Name: pending, Amount: net})
	case len(items) == 0:
		return items
	case approxEq(items[len(items)-1].Amount, net):
		return items
	case qty > 1 && approxEq(items[len(items)-1].Amount, unit) && approxEq(round2(qty*unit), net):
		items[len(items)-1].Amount = net
	}
	return items
}

// nextLineIsItemOf, lines[i] adli ve tutari net olan bir kalem satiri mi (BIM: adet satiri
// kalemin ustunde, "3X1,00" + "POPKEK MUZLU %08 3,00")?
func nextLineIsItemOf(lines []string, i int, net float64) bool {
	if i >= len(lines) || isTotalLabel(lines[i]) {
		return false
	}
	if strong, weak := nonItemLabel(lines[i]); strong || weak {
		return false
	}
	m := amountRe.FindAllStringIndex(maskDates(lines[i]), -1)
	if len(m) == 0 {
		return false
	}
	v, ok := parseAmount(lines[i][m[len(m)-1][0]:m[len(m)-1][1]])
	return ok && approxEq(v, net) && countLetters(cleanItemName(lines[i][:m[len(m)-1][0]])) >= 2
}

// extractItemsWithBare, kalemleri cikarir. Ayrica:
//   - ondalik ayiraci OCR'da dusmus ("*070", "100") satirlari ADAY olarak doner; adaylar yalnizca
//     toplamla dogrulaninca eklenir (recoverBareAmounts);
//   - yalnizca kisa bir etiket kelimesi yuzunden atlanan tutarli satirlari (skipped) doner;
//     mutabakat eksik farki bunlarla karsilastirip "atlanan satir" supheli olarak raporlar.
//
// Ozet satirlari (TOPLAM, ARA TOPLAM, KDV, INDIRIM, NAKIT, KREDI KARTI, PARA USTU...) kalem olmaz;
// extractSummary bunlari metadata'ya ayirir.
func extractItemsWithBare(lines []string, totalAmount *float64) ([]Item, []bareCandidate, []Item) {
	var items []Item
	var cands []bareCandidate
	var skipped []Item
	pendingName := "" // ustteki satir yalnizca urun adi (alttaki adet satirinin kalemi olabilir)
	rev := reversalLines(lines)
	for li, l := range lines {
		if isTotalLabel(l) {
			break // Toplam satirindan sonrasi odeme/alt bilgi
		}
		if isCancelMarker(l) {
			pendingName = "" // "** IPTAL **" bir urun adi degildir
			continue
		}
		if rev[li] {
			// Geri alma satiri ("KIVI *-69,22"): kalem eklenmez, iptal edilen onceki kalem dusulur.
			if name, v, ok := nameAndAmount(l); ok {
				items = applyReversal(items, name, v)
			}
			pendingName = ""
			continue
		}
		pending := pendingName
		pendingName = ""
		if q := qtyPrefixRe.FindStringSubmatchIndex(l); q != nil {
			qty := 0.0
			if q[2] >= 0 {
				qty, _ = strconv.ParseFloat(strings.ReplaceAll(l[q[2]:q[3]], ",", "."), 64)
			}
			unit, _ := parseAmount(l[q[4]:q[5]])
			rest := strings.TrimSpace(l[q[1]:])
			if m := amountRe.FindAllStringIndex(maskDates(rest), -1); len(m) > 0 &&
				countLetters(cleanItemName(rest[:m[len(m)-1][0]])) < 2 {
				net, _ := parseAmount(rest[m[len(m)-1][0]:m[len(m)-1][1]])
				items = applyQtyLine(items, pending, qty, unit, net)
				continue
			}
			if rest == "" && pending != "" && qty > 0 && !nextLineIsItemOf(lines, li+1, round2(qty*unit)) {
				// "CAY" + "2 ADET X 15,00": net yazilmamis, ad satirinin tutari yok -> miktar x birim.
				// (BIM duzeninde adet satiri ALTTAKI kaleme aittir; o durumda ustteki ad kullanilmaz.)
				items = append(items, Item{Name: pending, Amount: round2(qty * unit)})
				continue
			}
			l = rest // adet satiri kalem degildir; kalan (BIM: "3A0.25 ALISVERISPOSET %18 0.75") islenir
		}
		if strong, weak := nonItemLabel(l); strong || weak {
			if weak {
				if a := amountsIn(l); len(a) > 0 {
					skipped = append(skipped, Item{Name: cleanItemName(l), Amount: a[len(a)-1]})
				}
			}
			continue
		}
		masked := maskDates(l)
		matches := amountRe.FindAllStringIndex(masked, -1)
		if len(matches) == 0 {
			if m := bareAmountRe.FindStringSubmatchIndex(l); m != nil {
				if n, err := strconv.Atoi(l[m[2]:m[3]]); err == nil && n > 0 {
					name := cleanItemName(l[:m[0]])
					if countLetters(name) >= 2 {
						cands = append(cands, bareCandidate{Pos: len(items), Item: Item{Name: name, Amount: float64(n) / 100}})
					}
				}
				continue
			}
			if name := cleanItemName(l); countLetters(name) >= 3 && !isStarBanner(l) {
				pendingName = name
			}
			continue
		}
		lastMatch := matches[len(matches)-1]
		amtStr := masked[lastMatch[0]:lastMatch[1]]
		val, ok := parseAmount(amtStr)
		if !ok || val <= 0 {
			continue
		}
		if totalAmount != nil && math.Abs(val-*totalAmount) < 0.005 && len(lines) <= 3 {
			continue
		}
		namePart := strings.TrimSpace(l[:lastMatch[0]])
		namePart = cleanItemName(namePart)
		letters := 0
		for _, r := range namePart {
			if unicode.IsLetter(r) {
				letters++
			}
		}
		if letters >= 2 {
			if r := []rune(namePart); len(r) > 80 {
				namePart = string(r[:80])
			}
			items = append(items, Item{Name: namePart, Amount: val})
		}
	}
	return items, cands, skipped
}

// cleanItemName, kalem adindaki KDV orani ve sutun kalintilarini temizler. Fiyatin onunde "*"
// olan fislerde (`%08 *3,95`) ad "...  %08 *" ile biter; once "*" atilir, sonra oran.
func cleanItemName(s string) string {
	s = strings.TrimRight(strings.TrimSpace(s), " *+$")
	s = trailingXRe.ReplaceAllString(s, "") // "x1.00" gibi OCR kalintisi
	s = itemTailRe.ReplaceAllString(s, "")
	return strings.TrimSpace(strings.Trim(s, "*-=_#:+$ "))
}
