package digital

import (
	"net/mail"
	"net/url"
	"regexp"
	"strings"
)

// Gmail yönlendirme onayı: kullanıcı Gmail'de yönlendirme adresi eklediğinde Google, adrese `forwarding-noreply@google.com`
// göndericisinden onay kodu + onay bağlantısı içeren bir mail yollar. Bu mail fiş olarak kaydedilmez; kod/bağlantı
// saklanıp mobil istemciye sunulur.
const gmailForwardingSender = "forwarding-noreply@google.com"

// Onay bağlantısı yalnızca bu Google ana makinelerinden kabul edilir (sahte "onay" maili başka bir adrese yönlendirmesin).
var gmailLinkHosts = map[string]bool{"mail-settings.google.com": true, "mail.google.com": true}

var (
	gmailCodeLabelRe = regexp.MustCompile(`(?i)(?:code|kod[uü]?)\s*[:：]?\s*(\d{6,9})\b`)
	gmailCodeAnyRe   = regexp.MustCompile(`\b(\d{9})\b`)
	linkRe           = regexp.MustCompile(`https://[^\s"'<>)\]]+`)
)

// GmailConfirmation onay kodu ve (doğrulanmış) bağlantıyı döndürür.
type GmailConfirmation struct {
	Code string
	Link string
}

// DetectGmailConfirmation `from` göndericisi Google'ın yönlendirme adresi değilse ya da kod bulunamazsa ok=false.
// `text` düz metin, `htmlText` HTMLToText çıktısı, `rawHTML` ham HTML (href'ler için) olabilir; boşlar atlanır.
func DetectGmailConfirmation(from, text, htmlText, rawHTML string) (GmailConfirmation, bool) {
	addr := strings.ToLower(strings.TrimSpace(from))
	if a, err := mail.ParseAddress(from); err == nil {
		addr = strings.ToLower(a.Address)
	}
	if addr != gmailForwardingSender {
		return GmailConfirmation{}, false
	}
	body := text + "\n" + htmlText
	code := ""
	if m := gmailCodeLabelRe.FindStringSubmatch(body); m != nil {
		code = m[1]
	} else if m := gmailCodeAnyRe.FindStringSubmatch(body); m != nil {
		code = m[1]
	}
	if code == "" {
		return GmailConfirmation{}, false
	}
	link := ""
	for _, src := range []string{rawHTML, text} {
		for _, raw := range linkRe.FindAllString(src, -1) {
			raw = strings.ReplaceAll(raw, "&amp;", "&")
			raw = strings.TrimRight(raw, ".,;")
			u, err := url.Parse(raw)
			if err != nil || u.Scheme != "https" || !gmailLinkHosts[strings.ToLower(u.Hostname())] || u.Port() != "" || u.User != nil {
				continue
			}
			if !strings.HasPrefix(u.Path, "/mail/vf-") {
				continue
			}
			link = u.String()
			break
		}
		if link != "" {
			break
		}
	}
	return GmailConfirmation{Code: code, Link: link}, true
}
