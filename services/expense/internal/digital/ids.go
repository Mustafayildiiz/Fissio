// Package digital: dijital fiş (PDF / HTML e-posta / .eml) için saf, DB'siz yardımcılar — HTML → temiz metin,
// yönlendirme önsözü temizliği, belge kimliği (ETTN / VKN_FaturaNo) ve sipariş no çıkarımı, ön özet + resmi fatura
// birleştirme kararı, Gmail yönlendirme onayı yakalama ve EML/MIME ayrıştırma.
//
// Mobildeki Dart ikizi: fissio_mobile/lib/receipt_parser/{html_text,digital_receipt,digital_ids,merge_decision,eml}.dart.
// Ortak vektörler: repo kökü testdata/ (README'ye bakın). Otorite bu paketidir.
package digital

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"fissio/expense/internal/receiptparse"
)

var (
	ettnRe       = regexp.MustCompile(`\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b`)
	documentNoRe = regexp.MustCompile(`^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9]{10,11}_[A-Z0-9-]{3,32})$`)
	// Standart e-fatura/e-arşiv numarası: 3 karakter seri + 13 hane (yıl + sıra).
	invoiceNoRe = regexp.MustCompile(`\b[A-Za-z0-9]{3}\d{13}\b`)
	vknRe       = regexp.MustCompile(`\b\d{10,11}\b`)
	amountRe    = regexp.MustCompile(`(?:\d{1,3}(?:\.\d{3})+|\d+)[.,]\d{2}\b`)

	orderIDValidRe = regexp.MustCompile(`^[A-Z0-9][A-Z0-9.-]{3,40}$`)
	orderLabelRe   = regexp.MustCompile(`\b(?:siparis|order)\s*(?:(?:numarasi|numaraniz|numara|number|no|nr|kodu|id)\b|#|:)[\s:#.\-–—]*`)
	orderTokenRe   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.\-]{3,40}`)
)

func fold(s string) string { return receiptparse.FoldTR(s) }

func splitCRLF(text string) []string {
	return strings.Split(strings.ReplaceAll(text, "\r", ""), "\n")
}

// NormalizeDocumentNo belge kimliğini sunucudaki biçime çevirir: ETTN küçük harf, `VKN_FaturaNo` büyük harf.
// Geçerli değilse "" döner. (expense `normalizeDocumentNo` ve Dart `normalizeDocumentNo` ile aynı kural.)
func NormalizeDocumentNo(raw string) string {
	v := strings.TrimSpace(raw)
	if v == "" {
		return ""
	}
	if i := strings.Index(v, "_"); i >= 0 {
		v = v[:i+1] + strings.ToUpper(v[i+1:])
	} else {
		v = strings.ToLower(v)
	}
	if !documentNoRe.MatchString(v) {
		return ""
	}
	return v
}

// ExtractDocumentNo metinden belge kimliğini çıkarır: önce "ETTN" etiketli UUID, yoksa satıcı VKN'si + fatura
// numarası. Etiketsiz UUID, kısa fiş/sipariş/Z numarası asla kimlik olmaz. Bulunamazsa "".
func ExtractDocumentNo(text string) string {
	lines := splitCRLF(text)
	for i := range lines {
		if !strings.Contains(fold(lines[i]), "ettn") {
			continue
		}
		cands := []string{lines[i]}
		if i+1 < len(lines) {
			cands = append(cands, lines[i+1])
		}
		for _, l := range cands {
			if m := ettnRe.FindString(l); m != "" {
				return NormalizeDocumentNo(m)
			}
		}
	}
	vkn := ""
	for _, l := range lines {
		f := fold(l)
		if !(strings.Contains(f, "vkn") || strings.Contains(f, "vergi kimlik") || strings.Contains(f, "tckn") || strings.Contains(f, "t.c. kimlik")) {
			continue
		}
		if m := vknRe.FindString(l); m != "" {
			vkn = m
			break
		}
	}
	if vkn == "" {
		return ""
	}
	for i := range lines {
		f := fold(lines[i])
		if !(strings.Contains(f, "fatura no") || strings.Contains(f, "fatura numarasi") || strings.Contains(f, "belge no")) {
			continue
		}
		cands := []string{lines[i]}
		if i+1 < len(lines) {
			cands = append(cands, lines[i+1])
		}
		for _, l := range cands {
			if m := invoiceNoRe.FindString(l); m != "" {
				return NormalizeDocumentNo(vkn + "_" + m)
			}
		}
	}
	return ""
}

// NormalizeOrderID sipariş numarasını büyük harfe çevirir; geçersizse "".
func NormalizeOrderID(raw string) string {
	v := strings.ToUpper(strings.TrimSpace(raw))
	if !orderIDValidRe.MatchString(v) {
		return ""
	}
	return v
}

// ExtractOrderID platform sipariş kodunu çıkarır. YALNIZCA etiketli değer kabul edilir ("Sipariş No", "Sipariş
// Numarası", "Sipariş Kodu", "Order ID/Number/No"…): değer aynı satırda ya da (etiket satırı boşsa) sonraki
// satırın tamamıdır; en az bir rakam içermelidir (ör. `GPA.3345-1234-5678-12345`). Fatura/ETTN/fiş no asla
// sipariş no sayılmaz. Bulunamazsa "".
func ExtractOrderID(text string) string {
	lines := splitCRLF(text)
	for i, line := range lines {
		f := fold(line)
		loc := orderLabelRe.FindStringIndex(f)
		if loc == nil {
			continue
		}
		// fold() rune başına rune üretir; bayt konumunu rune konumuna çevirip özgün satırı dilimle.
		runes := []rune(line)
		start := utf8.RuneCountInString(f[:loc[1]])
		if start > len(runes) {
			start = len(runes)
		}
		rest := strings.TrimSpace(string(runes[start:]))
		if rest != "" {
			if id := orderTokenFrom(rest); id != "" {
				return id
			}
			continue
		}
		if i+1 < len(lines) {
			next := strings.TrimSpace(lines[i+1])
			if tok := orderTokenFrom(next); tok != "" && strings.EqualFold(strings.TrimRight(next, ".-"), tok) {
				return tok
			}
		}
	}
	return ""
}

func orderTokenFrom(s string) string {
	m := orderTokenRe.FindString(s)
	if m == "" {
		return ""
	}
	m = strings.TrimRight(m, ".-")
	hasDigit := false
	for _, r := range m {
		if unicode.IsDigit(r) {
			hasDigit = true
			break
		}
	}
	if !hasDigit {
		return ""
	}
	return NormalizeOrderID(m)
}

// HasUsableTextLayer: PDF/metin fiş ayrıştırmaya yetecek kadar dolu mu? En az 40 harf ve bir tutar.
func HasUsableTextLayer(pageTexts []string) bool {
	text := strings.Join(pageTexts, "\n")
	letters := 0
	for _, r := range text {
		if unicode.IsLetter(r) {
			letters++
		}
	}
	return letters >= 40 && amountRe.MatchString(text)
}
