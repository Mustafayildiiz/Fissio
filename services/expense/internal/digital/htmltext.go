package digital

import (
	"regexp"
	"strings"

	"golang.org/x/net/html"
)

// HTMLToText HTML e-posta gövdesini satır yapısını koruyarak saf metne çevirir (Dart ikizi: html_text.dart).
//
// Kurallar (ikisinde de aynı, ortak vektörler testdata/html/*.json):
//   - head/title/style/script/noscript/template/svg/iframe/object/button/select/form kontrolleri ve gizli
//     (hidden, display:none, visibility:hidden, font-size:0, max-height:0, opacity:0) öğeler atılır; img metin üretmez
//     (takip pikselleri bu yüzden kendiliğinden düşer).
//   - Blok öğeler (p, div, tr, li, table, h1-6, br…) satır sonu üretir; td/th hücreleri bir boşlukla ayrılır.
//   - Boşluk dizileri (nbsp dahil) tek boşluğa iner, boş satırlar atılır.
//   - Altbilgi/yasal uyarı/sosyal medya/abonelik satırları atılır (footerMarkers).
func HTMLToText(src string) string {
	doc, err := html.Parse(strings.NewReader(src))
	if err != nil {
		return ""
	}
	w := &textWalker{}
	w.walk(doc)
	w.flush()
	return dropFooterLines(w.lines)
}

// Boşlukları atılmış, küçük harfli style değerinde gizlilik izi ("font-size:0.9em" gizli sayılmaz).
var hiddenStyleRe = regexp.MustCompile(`display:none|visibility:hidden|(?:font-size|max-height|opacity):0(?:[^.\d]|$)`)

var skipTags = map[string]bool{
	"head": true, "title": true, "style": true, "script": true, "noscript": true, "template": true,
	"svg": true, "iframe": true, "object": true, "button": true, "select": true, "textarea": true,
	"img": true, "input": true, "meta": true, "link": true,
}

var blockTags = map[string]bool{
	"p": true, "div": true, "tr": true, "li": true, "ul": true, "ol": true, "table": true, "thead": true,
	"tbody": true, "tfoot": true, "h1": true, "h2": true, "h3": true, "h4": true, "h5": true, "h6": true,
	"br": true, "hr": true, "section": true, "article": true, "header": true, "footer": true, "blockquote": true,
	"pre": true, "address": true, "dl": true, "dt": true, "dd": true, "center": true, "main": true, "nav": true,
	"aside": true, "form": true, "body": true, "html": true,
}

type textWalker struct {
	cur   strings.Builder
	lines []string
}

func (w *textWalker) flush() {
	s := collapseSpaces(w.cur.String())
	w.cur.Reset()
	if s != "" {
		w.lines = append(w.lines, s)
	}
}

func isHidden(n *html.Node) bool {
	for _, a := range n.Attr {
		switch strings.ToLower(a.Key) {
		case "hidden":
			return true
		case "style":
			s := strings.ToLower(strings.Map(func(r rune) rune {
				if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
					return -1
				}
				return r
			}, a.Val))
			if hiddenStyleRe.MatchString(s) {
				return true
			}
		}
	}
	return false
}

func (w *textWalker) walk(n *html.Node) {
	switch n.Type {
	case html.TextNode:
		w.cur.WriteString(n.Data)
		return
	case html.ElementNode:
		tag := strings.ToLower(n.Data)
		if skipTags[tag] || isHidden(n) {
			return
		}
		block := blockTags[tag]
		if block {
			w.flush()
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			w.walk(c)
		}
		if block {
			w.flush()
		}
		if tag == "td" || tag == "th" {
			w.cur.WriteString(" ")
		}
		return
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		w.walk(c)
	}
}

// collapseSpaces boşluk/sekme/satır sonu/nbsp dizilerini tek boşluğa indirir ve kırpar.
func collapseSpaces(s string) string {
	var b strings.Builder
	space := false
	for _, r := range s {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '\f' || isInvisibleSpace(r) {
			space = true
			continue
		}
		if space && b.Len() > 0 {
			b.WriteByte(' ')
		}
		space = false
		b.WriteRune(r)
	}
	return b.String()
}

// footerMarkers: katlanmış (foldTR) satırda geçerse satır atılır.
var footerMarkers = []string{
	"abonelikten", "aboneligi", "unsubscribe", "e-posta tercih", "gizlilik politika", "kullanim kosul",
	"privacy policy", "terms of service", "terms of use", "bu e-posta", "bu eposta", "bu mail", "this email was sent",
	"this e-mail was sent", "you are receiving this", "you received this", "view in browser", "view this email",
	"tarayicida goruntule", "tarayicinizda", "tum haklari saklidir", "all rights reserved", "copyright", "©",
	"mersis", "kvkk", "kisisel verilerin", "facebook", "instagram", "twitter", "linkedin", "youtube", "tiktok",
	"follow us", "bizi takip", "do not reply", "lutfen yanitlamayin", "bu mesaj otomatik",
}

func dropFooterLines(lines []string) string {
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		f := fold(l)
		drop := false
		for _, m := range footerMarkers {
			if strings.Contains(f, m) {
				drop = true
				break
			}
		}
		if !drop {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}

// isInvisibleSpace: nbsp, sıfır genişlikli boşluklar, BOM, yumuşak tire, birleştirme işareti.
func isInvisibleSpace(r rune) bool {
	switch r {
	case 0xA0, 0xAD, 0x34F, 0x200B, 0x200C, 0x200D, 0xFEFF:
		return true
	}
	return false
}
