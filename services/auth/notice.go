package main

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/gin-gonic/gin"
)

// İşlenemeyen e-posta aktarımı bildirimi (expense -> auth iç API).
//
// Expense, kullanıcının e-posta adresini bilmez; yalnız bu TÜRE ÖZEL uca (genel bir "mail gönder" rölesi değil) kısa
// alanlar gönderir. Mail yalnız hesabın KAYITLI ve doğrulanmış adresine gider; silinmekte olan hesaba gitmez. Gelen
// mailin içeriğinden yalnız (temizlenmiş, kısaltılmış) konu kullanılır; bağlantı/HTML taşınmaz, mail düz metindir.
// Konu SALDIRGAN DENETİMİNDEDİR (sızan alias'a "Hesabınız askıya alındı: https://…" gönderilebilir): Fissio'nun güvenilir
// göndericisinden kullanıcının gelen kutusuna tıklanabilir bağlantı taşınmasın diye URL'ler kaldırılır, alan adı
// biçimindeki parçaların noktası kırılır (`evil[.]com`; e-posta istemcileri düz metni otomatik bağlantıya çevirir).

const (
	noticeFieldMax  = 200
	noticeSubjectMx = 120
)

// istanbul: Türkiye UTC+3 (2016'dan beri yaz saati yok). tzdata'ya bağlı olmasın diye sabit bölge.
var istanbul = time.FixedZone("TRT", 3*60*60)

type inboundFailureNotice struct {
	ProfileName string    `json:"profile_name"`
	MailSubject string    `json:"mail_subject"`
	ReceivedAt  time.Time `json:"received_at"`
	Reason      string    `json:"reason"`
}

var (
	// şema:// ya da www. ile başlayan parça (boşluğa kadar).
	noticeURLRe = regexp.MustCompile(`(?i)(?:\b[\p{L}][\p{L}\p{N}+.-]*://|\bwww\.)\S*`)
	// harf/rakamdan sonra gelen ve harfle devam eden nokta (alan adı); "12.345" gibi sayılar korunur.
	noticeDotRe = regexp.MustCompile(`([\p{L}\p{N}-])\.(\p{L})`)
)

// defangLinks bildirime yansıyan metinden tıklanabilir bağlantıları çıkarır.
func defangLinks(s string) string {
	s = noticeURLRe.ReplaceAllString(s, "[bağlantı kaldırıldı]")
	// Örtüşen eşleşmeler ("a.b.evil.com") tek geçişte kaçabilir: değişmeyene kadar tekrarla.
	for {
		next := noticeDotRe.ReplaceAllString(s, "$1[.]$2")
		if next == s {
			return s
		}
		s = next
	}
}

// cleanNoticeField kontrol karakterlerini atar, bağlantıları etkisizleştirir, boşlukları sadeleştirir ve uzunluğu sınırlar.
func cleanNoticeField(s string, max int) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
	s = defangLinks(strings.Join(strings.Fields(s), " "))
	if r := []rune(s); len(r) > max {
		s = string(r[:max]) + "…"
	}
	return s
}

// inboundFailureContent bildirim mailinin konusu ve düz metin gövdesi.
func inboundFailureContent(n inboundFailureNotice) (subject, body string) {
	subject = "Fissio: E-postayla gelen fişin işlenemedi"
	mailSubject := cleanNoticeField(n.MailSubject, noticeSubjectMx)
	if mailSubject == "" {
		mailSubject = "(konu yok)"
	}
	reason := cleanNoticeField(n.Reason, noticeFieldMax)
	if reason == "" {
		reason = "E-posta fiş olarak işlenemedi."
	}
	at := n.ReceivedAt
	if at.IsZero() {
		at = time.Now()
	}
	var b strings.Builder
	b.WriteString("Merhaba,\n\nFissio yönlendirme adresine gelen bir e-posta fiş olarak kaydedilemedi.\n\n")
	if p := cleanNoticeField(n.ProfileName, 40); p != "" {
		fmt.Fprintf(&b, "Profil: %s\n", p)
	}
	fmt.Fprintf(&b, "E-posta konusu: %s\n", mailSubject)
	fmt.Fprintf(&b, "Geliş zamanı: %s (TSİ)\n", at.In(istanbul).Format("02.01.2006 15:04"))
	fmt.Fprintf(&b, "Neden: %s\n\n", reason)
	b.WriteString("Fişi uygulamada \"Yeni fiş\" ile fotoğrafını çekerek ya da PDF/e-postayı \"Paylaş → Fissio\" ile " +
		"ekleyerek elle kaydedebilirsin. Ayrıntılar uygulamada Ayarlar → E-Posta ile Otomatik Fiş Aktarımı → " +
		"Son Aktarılan E-Postalar bölümünde.\n\n")
	b.WriteString("Bu bildirimleri uygulamada Ayarlar → Tercihler → \"Başarısız e-posta aktarımlarında e-posta ile " +
		"bilgilendir\" seçeneğinden kapatabilirsin.\n\nFissio")
	return subject, b.String()
}

// internalInboundFailure POST /internal/users/:id/inbound-failure -> 204 (gönderildi) | 404 (hesap yok / doğrulanmamış /
// siliniyor) | 400 | 502 (mail gönderilemedi).
func (h *handler) internalInboundFailure(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		fail(c, http.StatusBadRequest, "bad_request", "invalid user id")
		return
	}
	var n inboundFailureNotice
	if err := c.ShouldBindJSON(&n); err != nil {
		fail(c, http.StatusBadRequest, "bad_request", "invalid body")
		return
	}
	var email string
	err = h.db.QueryRow(`SELECT email FROM auth.users WHERE id = $1 AND email_verified_at IS NOT NULL AND deleting_at IS NULL`, id).Scan(&email)
	if errors.Is(err, sql.ErrNoRows) {
		fail(c, http.StatusNotFound, "not_found", "user not found")
		return
	}
	if err != nil {
		internalErr(c, err)
		return
	}
	subject, body := inboundFailureContent(n)
	if err := h.mailer.SendNotice(email, subject, body); err != nil {
		log.Printf("inbound failure notice for user %d: %v", id, err)
		fail(c, http.StatusBadGateway, "mail_failed", "notice could not be sent")
		return
	}
	c.Status(http.StatusNoContent)
}
