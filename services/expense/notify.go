package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

// Başarısız / işlenemeyen e-posta aktarımı bildirimi.
//
// Güvenlik: dış göndericiye ASLA otomatik yanıt (bounce) gönderilmez (sahte From ile geri saçılım riski). Bildirim yalnız
// alias'ın sahibi olan Fissio kullanıcısının KAYITLI hesap e-postasına gider. Expense e-posta adresini bilmez ve mail
// atmaz: auth'un iç API'sine (`POST /internal/users/:id/inbound-failure`, X-Internal-Token) türe özel bir istek
// gönderir; şablon ve gönderim (Resend/SMTP) auth'tadır.
//
// Karar (filtre + kullanıcı tercihi + saatlik sınır) webhook içinde SENKRON verilir (deterministik test); gönderim
// sınırlı bir kuyruk + tek worker goroutine ile ASENKRON yapılır, webhook yanıtı beklemez. Kuyruk doluysa bildirim düşer.

const (
	maxFailureNoticesPerHour = 5
	failureNoticeQueue       = 64
	failureNoticeTimeout     = 15 * time.Second // auth SMTP gönderimini senkron yapar
	failureNoticeSubjectMax  = 120
)

// failureNotice auth'a giden bildirim içeriği (düz metin alanlar; gelen maildeki bağlantılar asla taşınmaz).
type failureNotice struct {
	UserID      int64     `json:"-"`
	ProfileName string    `json:"profile_name"`
	MailSubject string    `json:"mail_subject"`
	ReceivedAt  time.Time `json:"received_at"`
	Reason      string    `json:"reason"`
}

type failureNotifier interface {
	// Enqueue bloklamaz; kuyruk doluysa false döner (bildirim düşer).
	Enqueue(n failureNotice) bool
}

// noNoticeReasons: bilgilendirme gerektirmeyen sonuçlar (mükerrer / zaten içe aktarılmış / Gmail onay maili).
var noNoticeReasons = map[string]bool{
	"duplicate_document":            true,
	"duplicate_order":               true,
	"already_imported":              true,
	"gmail_confirmation":            true,
	"gmail_confirmation_unreadable": true,
}

// shouldNotifyFailure: yalnız `failed` ve (mükerrer/onay dışı) `ignored` sonuçlar bildirilir.
func shouldNotifyFailure(histStatus, reason string) bool {
	switch histStatus {
	case historyFailed:
		return true
	case historyIgnored:
		return !noNoticeReasons[reason]
	}
	return false
}

// inboundReasonText neden kodunu kullanıcıya gösterilecek Türkçe açıklamaya çevirir. `failed` satırlarında reason
// "<kod>: <hata>" biçimindedir; iç hata metni kullanıcıya gönderilmez.
func inboundReasonText(histStatus, reason string) string {
	code := reason
	if histStatus == historyFailed {
		if i := strings.IndexByte(code, ':'); i >= 0 {
			code = code[:i]
		}
		return "Sunucu tarafında geçici bir hata oluştu (" + code + ")."
	}
	switch {
	case code == "no_amount":
		return "E-postada fiş tutarı bulunamadı."
	case code == "pdf_unreadable":
		return "Ekteki PDF'in metni okunamadı (taranmış/görsel PDF olabilir)."
	case code == "empty":
		return "E-postada okunabilir fiş içeriği bulunamadı."
	case code == "paused":
		return "Bu profil için e-posta aktarımı duraklatılmış durumda."
	case code == rejectedTooLarge:
		return "E-posta boyut sınırını aştığı için alınamadı."
	case code == "unreadable_payload":
		return "E-posta içeriği okunamadı."
	case code == "rate_limited":
		return "Kısa sürede çok fazla e-posta geldiği için bu e-posta işlenmedi."
	case code == "unknown_category":
		return "Fiş kategorisi belirlenemedi."
	case strings.HasPrefix(code, "invalid:"):
		return "Fiş bilgileri geçersiz görünüyor (" + cleanHistoryField(strings.TrimPrefix(code, "invalid:")) + ")."
	}
	return "E-posta fiş olarak işlenemedi (" + cleanHistoryField(code) + ")."
}

// maybeNotifyFailure webhook sonucuna göre (gerekirse) bildirimi kuyruğa ekler. Hatalar yutulur: bildirim webhook
// sonucunu asla değiştirmez.
func (h *handler) maybeNotifyFailure(t inboundTarget, subject, histStatus, reason string, now time.Time) {
	if h.notifier == nil || t.UserID == 0 || !shouldNotifyFailure(histStatus, reason) {
		return
	}
	s, err := h.loadInboundSettings(t.UserID)
	if err != nil {
		log.Printf("inbound: notify settings read failed for user %d: %v", t.UserID, err)
		return
	}
	if !s.NotifyFailures {
		return
	}
	if !h.notifyLim.allowWith(fmt.Sprintf("u:%d", t.UserID), now, maxFailureNoticesPerHour) {
		return
	}
	var pname string
	_ = h.db.QueryRow(`SELECT name FROM expense.profiles WHERE id = $1 AND user_id = $2`, t.ProfileID, t.UserID).Scan(&pname)
	n := failureNotice{
		UserID:      t.UserID,
		ProfileName: pname,
		MailSubject: noticeSubject(subject),
		ReceivedAt:  now.UTC(),
		Reason:      inboundReasonText(histStatus, reason),
	}
	if !h.notifier.Enqueue(n) {
		log.Printf("inbound: notify queue full, dropped notice for user %d", t.UserID)
	}
}

func noticeSubject(s string) string {
	s = cleanHistoryField(s)
	if r := []rune(s); len(r) > failureNoticeSubjectMax {
		s = string(r[:failureNoticeSubjectMax]) + "…"
	}
	return s
}

// authFailureNotifier: sınırlı kuyruk + tek worker; auth iç API'sine gönderir.
type authFailureNotifier struct {
	ch     chan failureNotice
	base   string
	token  string
	client *http.Client
}

func newAuthFailureNotifier(baseURL, token string, queue int) *authFailureNotifier {
	n := &authFailureNotifier{
		ch:     make(chan failureNotice, queue),
		base:   strings.TrimRight(baseURL, "/"),
		token:  token,
		client: &http.Client{Timeout: failureNoticeTimeout},
	}
	go n.run()
	return n
}

func (a *authFailureNotifier) Enqueue(n failureNotice) bool {
	select {
	case a.ch <- n:
		return true
	default:
		return false
	}
}

func (a *authFailureNotifier) run() {
	for n := range a.ch {
		if err := a.send(n); err != nil {
			log.Printf("inbound: failure notice for user %d not sent: %v", n.UserID, err)
		}
	}
}

func (a *authFailureNotifier) send(n failureNotice) error {
	body, err := json.Marshal(n)
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost, fmt.Sprintf("%s/internal/users/%d/inbound-failure", a.base, n.UserID), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(internalTokenHeader, a.token)
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	// 404: kullanıcı silinmiş / doğrulanmamış -> sessizce bırak.
	if resp.StatusCode/100 == 2 || resp.StatusCode == http.StatusNotFound {
		return nil
	}
	return fmt.Errorf("auth answered %d", resp.StatusCode)
}
