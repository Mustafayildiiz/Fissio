package digital

import (
	"net/mail"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// E-posta fişlerinde satıcı adı seçimi (marka adı SABİTLENMEZ; genel kurallar):
//  1. gövdede açık etiketli satır ("Restoran: X", "Satıcı X", "Mağaza: X", "İşletme", "Firma"),
//  2. ayrıştırıcının bulduğu satıcı — cümle / sipariş numarası DEĞİLSE,
//  3. yönlendirilmiş mailin önsözündeki "Gönderen:/From:" görünen adı (ya da domaini),
//  4. e-postanın gönderen görünen adı,
//  5. gönderen domaininin ikinci düzey adı,
//  6. "" (çağıran "E-posta fişi" yazar).
// Kişisel posta sağlayıcılarından (gmail, hotmail…) gelen adlar/domainler asla satıcı olmaz: kullanıcının kendi
// adresiyle elle yaptığı iletme satıcı sanılmasın.

var merchantLabelRe = regexp.MustCompile(`^(?:restoran adi|magaza adi|isletme adi|satici firma|satici|restoran|magaza|isletme|firma)\s*[:\-]?\s+(\S.*)$`)

// personalMailDomains kişisel posta sağlayıcıları: gönderen adı/domaini satıcı olamaz.
var personalMailDomains = map[string]bool{
	"gmail": true, "googlemail": true, "hotmail": true, "outlook": true, "live": true, "msn": true, "yahoo": true,
	"icloud": true, "me": true, "yandex": true, "proton": true, "protonmail": true, "mynet": true, "gmx": true,
	"aol": true, "zoho": true,
}

var secondLevelTLDs = map[string]bool{"com": true, "org": true, "net": true, "gov": true, "edu": true, "co": true, "gen": true, "web": true, "biz": true, "info": true}

// ChooseMerchant satıcı adını seçer (bkz. dosya başı); bulunamazsa "".
func ChooseMerchant(parsed, bodyText string, m *Message) string {
	if v := labeledMerchant(bodyText); v != "" {
		return v
	}
	if p := strings.TrimSpace(parsed); p != "" && !looksLikeSentence(p) {
		return p
	}
	if m == nil {
		return ""
	}
	if name := OriginalSender(m); name != "" {
		return name
	}
	if name, dom := splitAddress(m.From); name != "" && !personalMailDomains[domainLabel(dom)] {
		return name
	}
	if _, dom := splitAddress(m.From); dom != "" {
		if l := domainLabel(dom); l != "" && !personalMailDomains[l] {
			return titleCase(l)
		}
	}
	return ""
}

func labeledMerchant(text string) string {
	lines := splitCRLF(text)
	if len(lines) > 80 {
		lines = lines[:80]
	}
	for _, l := range lines {
		m := merchantLabelRe.FindStringSubmatch(fold(strings.TrimSpace(l)))
		if m == nil {
			continue
		}
		// Değeri özgün (katlanmamış) satırdan al: katlama rune sayısını korur.
		orig := []rune(strings.TrimSpace(l))
		folded := []rune(fold(strings.TrimSpace(l)))
		valLen := utf8.RuneCountInString(m[1])
		if len(folded) != len(orig) || valLen > len(orig) {
			continue
		}
		v := strings.TrimSpace(strings.Trim(string(orig[len(orig)-valLen:]), ":-–— "))
		if v != "" && utf8.RuneCountInString(v) <= 60 && countLetters(v) >= 2 && !looksLikeSentence(v) {
			return v
		}
	}
	return ""
}

func countLetters(s string) int {
	n := 0
	for _, r := range s {
		if unicode.IsLetter(r) {
			n++
		}
	}
	return n
}

// looksLikeSentence: işletme adı yerine cümle ya da sipariş numarası gibi duran metin.
func looksLikeSentence(s string) bool {
	s = strings.TrimSpace(s)
	if s == "" {
		return true
	}
	if utf8.RuneCountInString(s) > 40 || len(strings.Fields(s)) > 5 {
		return true
	}
	words := len(strings.Fields(s))
	switch last := s[len(s)-1:]; {
	case strings.ContainsAny(last, "!?:;,") && utf8.RuneCountInString(s) >= 5:
		return true
	case last == "." && words >= 4: // "Ltd." / "A.Ş." kısaltması işletme adıdır; çok kelimeli cümle değildir
		return true
	case strings.Contains(s, ", "):
		return true
	}
	f := fold(s)
	if strings.Contains(f, "siparis") || strings.Contains(f, "order") || strings.Contains(s, "#") {
		return true
	}
	letters, digits := 0, 0
	for _, r := range s {
		switch {
		case unicode.IsLetter(r):
			letters++
		case unicode.IsDigit(r):
			digits++
		}
	}
	// Sipariş/fiş numarası gibi: harfsiz ya da çok rakamlı ("A101", "7-Eleven" gerçek işletmedir).
	return letters == 0 || (digits >= 4 && digits*2 > letters)
}

// OriginalSender yönlendirilmiş mailin önsözündeki ("---------- Forwarded message ----------" / "İletilen ileti" ya da
// Outlook başlık bloğu) "Gönderen:/From:/Kimden:" satırından özgün göndericinin görünen adını (yoksa domain adını) verir.
// Önsöz atılmadan ÖNCE okunur (StripForwardPreamble atar).
func OriginalSender(m *Message) string {
	for _, text := range []string{m.Text, HTMLToText(m.HTML)} {
		if v := forwardedFromName(text); v != "" {
			return v
		}
	}
	return ""
}

func forwardedFromName(text string) string {
	lines := splitCRLF(text)
	limit := len(lines)
	if limit > 60 {
		limit = 60
	}
	hasMarker := false
	for i := 0; i < limit; i++ {
		f := fold(strings.TrimSpace(quotePfxRe.ReplaceAllString(strings.TrimSpace(lines[i]), "")))
		if fwdMarkerRe.MatchString(f) {
			hasMarker = true
			continue
		}
		if !hdrFromRe.MatchString(f) {
			continue
		}
		// Marker yoksa yalnızca metnin başındaki başlık bloğu (ilk 8 satır) önsöz sayılır.
		if !hasMarker && i > 8 {
			return ""
		}
		raw := strings.TrimSpace(quotePfxRe.ReplaceAllString(strings.TrimSpace(lines[i]), ""))
		if k := strings.Index(raw, ":"); k >= 0 {
			raw = strings.TrimSpace(raw[k+1:])
		}
		name, dom := splitAddress(raw)
		if l := domainLabel(dom); personalMailDomains[l] {
			continue
		}
		if name != "" {
			return name
		}
		if l := domainLabel(dom); l != "" {
			return titleCase(l)
		}
	}
	return ""
}

// splitAddress "Ad Soyad <a@b.c>" → (ad, domain); ayrıştırılamazsa tırnaksız ham metin ad sayılmaz.
func splitAddress(s string) (name, domain string) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", ""
	}
	if a, err := mail.ParseAddress(s); err == nil {
		if i := strings.LastIndex(a.Address, "@"); i >= 0 {
			domain = strings.ToLower(a.Address[i+1:])
		}
		return strings.TrimSpace(a.Name), domain
	}
	if i := strings.LastIndex(s, "@"); i >= 0 {
		domain = strings.ToLower(strings.Trim(s[i+1:], "<>\" "))
	}
	return "", domain
}

// domainLabel "mail.getiryemek.com.tr" → "getiryemek"; "" = bulunamadı.
func domainLabel(domain string) string {
	labels := strings.Split(strings.ToLower(strings.TrimSpace(domain)), ".")
	for len(labels) > 1 && labels[len(labels)-1] == "" {
		labels = labels[:len(labels)-1]
	}
	if len(labels) < 2 {
		return ""
	}
	labels = labels[:len(labels)-1] // TLD
	if n := len(labels); n >= 2 && secondLevelTLDs[labels[n-1]] {
		labels = labels[:n-1] // com.tr, co.uk…
	}
	return labels[len(labels)-1]
}

func titleCase(s string) string {
	r := []rune(s)
	if len(r) == 0 {
		return ""
	}
	r[0] = unicode.ToUpper(r[0])
	return string(r)
}

// ProductLine fiyatsız ürün satırı: "Ürün Adı - (Adet: 2)".
type ProductLine struct {
	Name string
	Qty  int
}

var productQtyRe = regexp.MustCompile(`(?i)^(.{2,}?)[\s\-–—]*\(\s*(?:adet|qty|miktar)\s*[:x]?\s*(\d{1,3})\s*\)\s*$`)

// ProductLinesWithQty yalnızca ad + "(Adet: N)" taşıyan (fiyatsız) ürün satırlarını verir (GetirYemek tarzı özetler).
func ProductLinesWithQty(text string) []ProductLine {
	var out []ProductLine
	for _, l := range splitCRLF(text) {
		m := productQtyRe.FindStringSubmatch(strings.TrimSpace(l))
		if m == nil {
			continue
		}
		name := strings.TrimSpace(m[1])
		if countLetters(name) < 3 {
			continue
		}
		q := 0
		for _, c := range m[2] {
			q = q*10 + int(c-'0')
		}
		if q <= 0 {
			q = 1
		}
		out = append(out, ProductLine{Name: name, Qty: q})
		if len(out) >= 20 {
			break
		}
	}
	return out
}
