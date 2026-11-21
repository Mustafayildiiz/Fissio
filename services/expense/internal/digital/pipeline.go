package digital

import "strings"

// Metin kaynağı (ReceiptText sonucu).
const (
	SourcePDF           = "pdf"
	SourceHTML          = "html"
	SourceText          = "text"
	SourcePDFUnreadable = "pdf_unreadable" // yalnızca okunamayan PDF eki vardı
	SourceEmpty         = "empty"
)

// JoinPageTexts sayfa metinlerini tek metne birleştirir (boş sayfalar atılır).
func JoinPageTexts(pages []string) string {
	var out []string
	for _, p := range pages {
		p = strings.TrimSpace(strings.ReplaceAll(p, "\r", ""))
		if p != "" {
			out = append(out, p)
		}
	}
	return strings.Join(out, "\n")
}

// ReceiptText e-postadan fiş metnini şu öncelikle seçer: (1) PDF eki (ya da zip içindeki PDF) metin katmanı —
// metin katmanı boş/taranmış ise sunucu OCR yapmaz, sonraki kaynağa düşer; (2) HTML gövde (temizlenip); (3) düz metin.
// HTML ve düz metinden "İlet" önsözü atılır. Hiçbiri yoksa kaynak SourcePDFUnreadable (PDF vardı ama okunamadı)
// ya da SourceEmpty olur.
func ReceiptText(m *Message, pdfPages func([]byte) ([]string, error)) (text, source string) {
	if pdfPages == nil {
		pdfPages = PDFPageTexts
	}
	for _, a := range m.PDFs {
		pages, err := pdfPages(a.Data)
		if err == nil && HasUsableTextLayer(pages) {
			return JoinPageTexts(pages), SourcePDF
		}
	}
	if m.HTML != "" {
		if t := StripForwardPreamble(HTMLToText(m.HTML)); strings.TrimSpace(t) != "" {
			return t, SourceHTML
		}
	}
	if m.Text != "" {
		if t := StripForwardPreamble(m.Text); strings.TrimSpace(t) != "" {
			return t, SourceText
		}
	}
	if len(m.PDFs) > 0 {
		return "", SourcePDFUnreadable
	}
	return "", SourceEmpty
}
