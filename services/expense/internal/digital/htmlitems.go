package digital

import (
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

// TableItem HTML sipariş özeti tablosundan çıkan kalem (Yemeksepeti, Getir, Trendyol Yemek vb.).
type TableItem struct {
	Name        string
	Qty         int
	AmountCents int64 // satır toplamı
}

// DisplayName adet 1'den büyükse "N x Ad" verir.
func (t TableItem) DisplayName() string {
	if t.Qty > 1 {
		return strconv.Itoa(t.Qty) + " x " + t.Name
	}
	return t.Name
}

var (
	moneyCellRe = regexp.MustCompile(`(?i)^(?:₺\s*)?(\d{1,3}(?:\.\d{3})+|\d+)([.,]\d{2})\s*(?:tl|₺|try)?$`)
	// Ondalıksız tutar YALNIZ açık para birimiyle ("665 TRY", "355TRY", "-310 TRY"): çıplak "2" adet hücresidir.
	// Baştaki eksi (-, −) kampanya/indirim satırıdır.
	intMoneyCellRe = regexp.MustCompile(`(?i)^([-−])?\s?(\d{1,3}(?:\.\d{3})+|\d+)\s?(?:tl|₺|try)$`)
	qtyCellRe      = regexp.MustCompile(`(?i)^(?:(\d{1,3})\s*(?:x|×|adet|adt)?|(?:x|×)\s*(\d{1,3}))$`)
	qtyPrefixRe    = regexp.MustCompile(`(?i)^(\d{1,3})\s*(?:x|×|adet)\s+(.+)$|^(\d{1,3})x\s*(.+)$`)
)

// Özet satırı etiketleri (katlanmış, tam etiket ya da etiket + boşluk önekiyle eşleşir). "Teslimat Ücreti",
// "Poşet", "Servis Ücreti" gibi fiyata dahil gerçek masraflar BİLEREK burada yoktur: kalem olarak korunur.
var tableSummaryLabels = []string{
	"ara toplam", "genel toplam", "toplam tutar", "toplam kdv", "toplam indirim", "toplam", "kdv", "indirim",
	"odenecek tutar", "odenen tutar", "vergiler dahil toplam", "sepet toplami", "kdv dahil toplam",
}

func isSummaryLabel(name string) bool {
	f := strings.TrimSpace(strings.TrimRight(strings.TrimSpace(fold(name)), ":"))
	for _, l := range tableSummaryLabels {
		if f == l || strings.HasPrefix(f, l+" ") || strings.HasPrefix(f, l+":") || strings.HasPrefix(f, l+"(") {
			return true
		}
	}
	return false
}

// moneyCents para hücresini kuruşa çevirir; eksi işaretli hücre negatif döner (kalem olmaz, bkz. rowItem).
func moneyCents(s string) (int64, bool) {
	s = strings.TrimSpace(s)
	if m := intMoneyCellRe.FindStringSubmatch(s); m != nil {
		w, err := strconv.ParseInt(strings.ReplaceAll(m[2], ".", ""), 10, 64)
		if err != nil {
			return 0, false
		}
		if m[1] != "" {
			return -w * 100, true
		}
		return w * 100, true
	}
	m := moneyCellRe.FindStringSubmatch(s)
	if m == nil {
		return 0, false
	}
	whole := strings.ReplaceAll(m[1], ".", "")
	frac := m[2][1:]
	w, err := strconv.ParseInt(whole, 10, 64)
	if err != nil {
		return 0, false
	}
	f, _ := strconv.ParseInt(frac, 10, 64)
	return w*100 + f, true
}

// HTMLTableItems HTML gövdedeki sipariş tablosu satırlarından kalemleri çıkarır. HTMLToText çıktısını DEĞİŞTİRMEZ
// (Dart ikizi/golden vektörler korunur); yalnızca genel metin ayrıştırıcı kalem bulamadığında ya da tutarsız
// kaldığında kullanılan ek bir kaynaktır.
//
// Satır biçimleri: [ad, tutar], [adet, ad, tutar], [ad, adet, birim, tutar], "2 x Ad" öneki. Son para hücresi satır
// toplamıdır. Para hücresi olmayan satırlar (başlık) ve özet satırları atılır.
func HTMLTableItems(src string) []TableItem {
	doc, err := html.Parse(strings.NewReader(src))
	if err != nil {
		return nil
	}
	var out []TableItem
	var visit func(n *html.Node)
	visit = func(n *html.Node) {
		if n.Type == html.ElementNode {
			tag := strings.ToLower(n.Data)
			if skipTags[tag] || isHidden(n) {
				return
			}
			if tag == "tr" && !hasDescendantTable(n) {
				if it, ok := rowItem(n); ok {
					out = append(out, it)
				}
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			visit(c)
		}
	}
	visit(doc)
	if len(out) > 200 {
		out = out[:200]
	}
	return out
}

func hasDescendantTable(n *html.Node) bool {
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type == html.ElementNode && (strings.EqualFold(c.Data, "table") || hasDescendantTable(c)) {
			return true
		}
	}
	return false
}

func cellText(n *html.Node, b *strings.Builder) {
	switch n.Type {
	case html.TextNode:
		b.WriteString(n.Data)
		b.WriteByte(' ')
		return
	case html.ElementNode:
		if skipTags[strings.ToLower(n.Data)] || isHidden(n) {
			return
		}
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		cellText(c, b)
	}
}

func rowItem(tr *html.Node) (TableItem, bool) {
	var cells []string
	for c := tr.FirstChild; c != nil; c = c.NextSibling {
		if c.Type != html.ElementNode {
			continue
		}
		if t := strings.ToLower(c.Data); t != "td" && t != "th" {
			continue
		}
		var b strings.Builder
		cellText(c, &b)
		if s := collapseSpaces(b.String()); s != "" {
			cells = append(cells, s)
		}
	}
	if len(cells) < 2 {
		return TableItem{}, false
	}
	amountIdx := -1
	var cents int64
	for i := len(cells) - 1; i >= 0; i-- {
		if v, ok := moneyCents(cells[i]); ok {
			amountIdx, cents = i, v
			break
		}
	}
	if amountIdx <= 0 || cents <= 0 {
		return TableItem{}, false
	}
	qty, name := 0, ""
	for _, c := range cells[:amountIdx] {
		if _, ok := moneyCents(c); ok {
			continue // birim fiyat
		}
		if m := qtyCellRe.FindStringSubmatch(c); m != nil {
			if q, _ := strconv.Atoi(m[1] + m[2]); q > 0 && qty == 0 {
				qty = q
			}
			continue
		}
		if name == "" {
			name = c
		}
	}
	if name == "" || !strings.ContainsFunc(name, func(r rune) bool { return r > '9' }) {
		return TableItem{}, false
	}
	if m := qtyPrefixRe.FindStringSubmatch(name); m != nil {
		q, rest := m[1], m[2]
		if q == "" {
			q, rest = m[3], m[4]
		}
		if n, _ := strconv.Atoi(q); n > 0 && strings.TrimSpace(rest) != "" {
			if qty == 0 {
				qty = n
			}
			name = strings.TrimSpace(rest)
		}
	}
	if isSummaryLabel(name) {
		return TableItem{}, false
	}
	if qty == 0 {
		qty = 1
	}
	return TableItem{Name: name, Qty: qty, AmountCents: cents}, true
}
