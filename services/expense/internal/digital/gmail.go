package digital

import (
	"encoding/base64"
	"net/mail"
	"net/url"
	"regexp"
	"strings"
	"unicode/utf8"
)

// Gmail yönlendirme onayı: kullanıcı Gmail'de yönlendirme adresi eklediğinde Google, adrese `forwarding-noreply@google.com`
// göndericisinden onay kodu + onay bağlantısı içeren bir mail yollar (Türkçe/İngilizce şablon). Bu mail fiş olarak
// kaydedilmez; kod/bağlantı saklanıp mobil istemciye sunulur.
//
// Algılama dilden bağımsızdır ve şu işaretlerden BİRİ yeterlidir:
//   - gönderen `forwarding-noreply@google.com` — kod/bağlantı çıkmasa bile onay maili sayılır;
//   - herhangi bir kaynakta (düz metin, HTML, ham MIME, konu) doğrulanmış Google onay bağlantısı;
//   - başka bir google.com / *.google.com göndericisinden gelen ve ETİKETLİ onay kodu içeren mail.
//
// Kaynaklar quoted-printable (`=\r\n` yumuşak satır sonu, `=3D`) ve base64 kodlu olsa da çözülerek taranır.

// Onay bağlantısı yalnızca bu Google ana makinelerinden kabul edilir (sahte "onay" maili başka bir adrese yönlendirmesin).
var gmailLinkHosts = map[string]bool{"mail-settings.google.com": true, "mail.google.com": true}

var (
	gmailCodeLabelRe   = regexp.MustCompile(`(?i)\b(?:confirmation\s+code|verification\s+code|onay\s+kod[uü]?|do[gğ]rulama\s+kod[uü]?|code|kod[uü]?)\s*(?:is|:|：|-|–)?\s*#?(\d{6,9})\b`)
	gmailCodeSubjectRe = regexp.MustCompile(`\(#(\d{6,9})\)`)
	gmailCodeAnyRe     = regexp.MustCompile(`(?:^|[^\d])(\d{9})(?:[^\d]|$)`)
	linkRe             = regexp.MustCompile(`https://[^\s"'<>)\]]+`)
	qpSoftBreakRe      = regexp.MustCompile(`=\r?\n`)
	qpHexRe            = regexp.MustCompile(`=([0-9A-Fa-f]{2})`)
	base64BlobRe       = regexp.MustCompile(`^[A-Za-z0-9+/=\s]{40,}$`)
)

// GmailConfirmation onay kodu ve (doğrulanmış) bağlantıyı döndürür; ikisi de boş olabilir.
type GmailConfirmation struct {
	Code string
	Link string
}

// googleSender gönderen adresini ve google.com / *.google.com olup olmadığını verir.
func googleSender(from string) (addr string, google bool) {
	addr = strings.ToLower(strings.TrimSpace(from))
	if a, err := mail.ParseAddress(from); err == nil {
		addr = strings.ToLower(a.Address)
	}
	at := strings.LastIndex(addr, "@")
	if at <= 0 {
		return addr, false
	}
	d := strings.TrimRight(addr[at+1:], ".>")
	return addr, d == "google.com" || strings.HasSuffix(d, ".google.com")
}

// decodeQP quoted-printable'ı hata toleranslı çözer (`=\r\n` silinir, `=XX` bayta çevrilir).
func decodeQP(s string) string {
	if !strings.Contains(s, "=") {
		return s
	}
	s = qpSoftBreakRe.ReplaceAllString(s, "")
	return qpHexRe.ReplaceAllStringFunc(s, func(m string) string {
		return string([]byte{byte(hexVal(m[1])<<4 | hexVal(m[2]))})
	})
}

func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	default:
		return int(c-'A') + 10
	}
}

// expandSources her kaynağın ham, quoted-printable ve (tümü base64 görünüyorsa) base64 çözülmüş hâllerini verir.
func expandSources(in []string) []string {
	var out []string
	for _, s := range in {
		if strings.TrimSpace(s) == "" {
			continue
		}
		out = append(out, s)
		if qp := decodeQP(s); qp != s {
			out = append(out, qp)
		}
		if t := strings.TrimSpace(s); base64BlobRe.MatchString(t) {
			if b, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(t), "")); err == nil && utf8.Valid(b) {
				out = append(out, string(b))
			}
		}
	}
	return out
}

// validGmailLink ham bir URL'yi `&amp;` ve noktalamadan arındırıp Google onay bağlantısı olup olmadığına bakar.
func validGmailLink(raw string) (string, bool) {
	raw = strings.ReplaceAll(raw, "&amp;", "&")
	raw = strings.TrimRight(raw, ".,;")
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Port() != "" || u.User != nil {
		return "", false
	}
	host := strings.ToLower(u.Hostname())
	if !gmailLinkHosts[host] {
		return "", false
	}
	switch {
	case strings.HasPrefix(u.Path, "/mail/vf-"):
	case host == "mail-settings.google.com" && strings.HasPrefix(u.Path, "/mail/"):
	default:
		// mail.google.com/mail/... sıradan Gmail bağlantısıdır (altbilgi vb.); yalnızca /mail/vf- onay sayılır.
		return "", false
	}
	return u.String(), true
}

// DetectGmailConfirmation mail bir Gmail yönlendirme onayı değilse ok=false. `text` düz metin, `htmlText` HTMLToText
// çıktısı, `rawHTML` ham HTML (href'ler için); `extra` ek kaynaklar (konu, ham MIME …). Boşlar atlanır.
func DetectGmailConfirmation(from, text, htmlText, rawHTML string, extra ...string) (GmailConfirmation, bool) {
	addr, google := googleSender(from)
	forwarding := google && strings.HasPrefix(addr, "forwarding-noreply@")

	sources := expandSources(append([]string{text, htmlText, rawHTML}, extra...))

	code := ""
	for _, src := range sources {
		if m := gmailCodeLabelRe.FindStringSubmatch(src); m != nil {
			code = m[1]
			break
		}
		if m := gmailCodeSubjectRe.FindStringSubmatch(src); m != nil {
			code = m[1]
			break
		}
	}
	if code == "" && forwarding {
		// Etiket bulunamadı: Google'ın onay mailinde tek başına duran 9 haneli sayı koddur.
		for _, src := range sources {
			if m := gmailCodeAnyRe.FindStringSubmatch(src); m != nil {
				code = m[1]
				break
			}
		}
	}

	link := ""
	for _, src := range sources {
		for _, loc := range linkRe.FindAllStringIndex(src, -1) {
			raw := src[loc[0]:loc[1]]
			// `...=\r\n` = quoted-printable yumuşak satır sonunda kesilmiş URL; çözülmüş kaynak tam hâlini verir.
			if strings.HasSuffix(raw, "=") && (strings.HasPrefix(src[loc[1]:], "\n") || strings.HasPrefix(src[loc[1]:], "\r\n")) {
				continue
			}
			l, ok := validGmailLink(raw)
			if !ok {
				continue
			}
			if link == "" || (strings.Contains(l, "/mail/vf-") && !strings.Contains(link, "/mail/vf-")) {
				link = l
			}
		}
	}

	switch {
	case forwarding, link != "":
		return GmailConfirmation{Code: code, Link: link}, true
	case google && code != "":
		// Başka bir Google göndericisi: yalnızca ETİKETLİ kod varken onay say (Google Play/Pay fişlerini yutma).
		return GmailConfirmation{Code: code}, true
	}
	return GmailConfirmation{}, false
}
