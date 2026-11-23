package main

import (
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/mail"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"fissio/expense/internal/digital"
)

// E-posta ile otomatik fiş aktarımı: kullanıcıya özel tahmin edilemez adres (<alias>@INBOUND_EMAIL_DOMAIN) + harici posta
// yönlendiricisinden (Cloudflare Email Worker / Mailgun / SendGrid) gelen mailleri karşılayan webhook.
//
// Güvenlik: webhook X-Webhook-Secret (sabit zamanlı) ile korunur; bilinmeyen alias/okunamayan mail 200 `ignored` döner
// (sağlayıcı yeniden deneme fırtınası ve alias sızdırma olmasın). Alias başına saatlik sınır vardır.

const (
	defaultInboundMaxBytes = 15 << 20
	aliasMaxPerHour        = 60
	confirmationTTLHours   = 24
	maxConfirmationsKept   = 5
)

type inboundConfig struct {
	// Domain: alias alan adı (ör. fis.fissio.app); boş = özellik kapalı.
	Domain string
	// Secret: webhook paylaşılan sırrı; boşsa webhook her isteği reddeder.
	Secret   string
	MaxBytes int64
	// PDFText: testlerde değiştirilebilir PDF metin okuyucu (nil = digital.PDFPageTexts).
	PDFText func([]byte) ([]string, error)
}

func inboundConfigFromEnv() inboundConfig {
	max := int64(envInt("INBOUND_MAX_BYTES", defaultInboundMaxBytes))
	return inboundConfig{
		Domain:   strings.ToLower(strings.TrimPrefix(strings.TrimSpace(os.Getenv("INBOUND_EMAIL_DOMAIN")), "@")),
		Secret:   os.Getenv("INBOUND_WEBHOOK_SECRET"),
		MaxBytes: max,
	}
}

func (c inboundConfig) enabled() bool { return c.Domain != "" }

func (c inboundConfig) address(alias string) string { return alias + "@" + c.Domain }

func (c inboundConfig) maxBytes() int64 {
	if c.MaxBytes <= 0 {
		return defaultInboundMaxBytes
	}
	return c.MaxBytes
}

// aliasLimiter alias başına kayan saatlik sayaç.
type aliasLimiter struct {
	mu   sync.Mutex
	hits map[string][]time.Time
}

func (l *aliasLimiter) allow(alias string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.hits == nil {
		l.hits = map[string][]time.Time{}
	}
	cut := now.Add(-time.Hour)
	kept := l.hits[alias][:0]
	for _, t := range l.hits[alias] {
		if t.After(cut) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= aliasMaxPerHour {
		l.hits[alias] = kept
		return false
	}
	l.hits[alias] = append(kept, now)
	return true
}

// inboundLimiter süreç geneli alias başına sayaç (alias rastgele olduğundan testler birbirini etkilemez).
var inboundLimiter aliasLimiter

// ---- Webhook ------------------------------------------------------------------------------------------------------

// flexStrings: JSON'da tek string ya da string dizisi.
type flexStrings []string

func (f *flexStrings) UnmarshalJSON(b []byte) error {
	var one string
	if json.Unmarshal(b, &one) == nil {
		*f = flexStrings{one}
		return nil
	}
	var many []string
	if err := json.Unmarshal(b, &many); err != nil {
		*f = nil
		return nil // beklenmeyen biçim: yok say
	}
	*f = many
	return nil
}

type inboundAttachment struct {
	Filename      string `json:"filename"`
	ContentType   string `json:"content_type"`
	ContentBase64 string `json:"content_base64"`
}

// inboundPayload: Cloudflare Email Worker / özel yönlendirici JSON'u. Zarf alıcısı (to/recipient/envelope.to) alias'ın
// asıl kaynağıdır: otomatik yönlendirmede `To:` başlığı kullanıcının kendi adresidir.
type inboundPayload struct {
	To        flexStrings `json:"to"`
	Recipient flexStrings `json:"recipient"`
	Envelope  struct {
		To flexStrings `json:"to"`
	} `json:"envelope"`
	From        string              `json:"from"`
	Subject     string              `json:"subject"`
	Text        string              `json:"text"`
	HTML        string              `json:"html"`
	Raw         string              `json:"raw"`
	RawBase64   string              `json:"raw_base64"`
	MessageID   string              `json:"message_id"`
	Attachments []inboundAttachment `json:"attachments"`
	// Rejected: yönlendiricinin gövdesiz bildirimi (yalnız "too_large" kabul edilir: Worker maili boyut sınırı
	// nedeniyle göndermedi). Size bilgi amaçlıdır.
	Rejected string `json:"rejected"`
	Size     int64  `json:"size"`

	// rawBytes: ham message/rfc822 gövdesi (JSON'a girmez). Ayrı tutulur ki 15 MB'lık mail string'e ve geri kopyalanmasın.
	rawBytes []byte
}

// rejectedTooLarge yönlendiricinin "boyut sınırı aşıldı, gövde gönderilmedi" bildirimi.
const rejectedTooLarge = "too_large"

// gmailScanLimit: Gmail onay tespitine verilen ham MIME'ın üst sınırı (onay mailleri birkaç KB'tır; büyük ekli mailde
// megabaytlarca base64 üzerinde regex taraması yapılmasın).
const gmailScanLimit = 1 << 20

// rawMIME ham MIME baytları: rfc822 gövdesi > JSON `raw_base64` > JSON `raw`.
func (p inboundPayload) rawMIME() []byte {
	if len(p.rawBytes) > 0 {
		return p.rawBytes
	}
	if p.RawBase64 != "" {
		if b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(p.RawBase64)); err == nil {
			return b
		}
	}
	if p.Raw != "" {
		return []byte(p.Raw)
	}
	return nil
}

// readInbound webhook gövdesini (JSON, multipart/form-data ya da ham message/rfc822) ortak biçime çevirir.
func (h *handler) readInbound(c *gin.Context) (inboundPayload, error) {
	var p inboundPayload
	ct := strings.ToLower(c.GetHeader("Content-Type"))
	switch {
	case strings.HasPrefix(ct, "application/json"):
		err := json.NewDecoder(c.Request.Body).Decode(&p)
		return p, err
	case strings.HasPrefix(ct, "multipart/form-data"), strings.HasPrefix(ct, "application/x-www-form-urlencoded"):
		if err := c.Request.ParseMultipartForm(8 << 20); err != nil && !errors.Is(err, http.ErrNotMultipart) {
			return p, err
		}
		get := func(keys ...string) string {
			for _, k := range keys {
				if v := c.PostForm(k); v != "" {
					return v
				}
			}
			return ""
		}
		// Mailgun: recipient, body-plain, body-html, body-mime; SendGrid: to, text, html, email (ham MIME), envelope JSON.
		p.Recipient = flexStrings{get("recipient")}
		p.To = flexStrings{get("to", "To")}
		if env := get("envelope"); env != "" {
			_ = json.Unmarshal([]byte(env), &p.Envelope)
		}
		p.From = get("from", "From", "sender")
		p.Subject = get("subject", "Subject")
		p.Text = get("body-plain", "text")
		p.HTML = get("body-html", "html")
		p.Raw = get("body-mime", "email", "raw")
		p.MessageID = get("Message-Id", "message-id")
		if c.Request.MultipartForm != nil {
			for _, fhs := range c.Request.MultipartForm.File {
				for _, fh := range fhs {
					f, err := fh.Open()
					if err != nil {
						continue
					}
					data, _ := io.ReadAll(io.LimitReader(f, 20<<20))
					f.Close()
					p.Attachments = append(p.Attachments, inboundAttachment{
						Filename: fh.Filename, ContentType: fh.Header.Get("Content-Type"),
						ContentBase64: base64.StdEncoding.EncodeToString(data)})
				}
			}
		}
		return p, nil
	default: // message/rfc822, text/plain: ham MIME; alıcı ?rcpt= ile verilebilir
		b, err := io.ReadAll(c.Request.Body)
		p.rawBytes = b
		if r := c.Query("rcpt"); r != "" {
			p.Recipient = flexStrings{r}
		}
		return p, err
	}
}

// buildMessage payload'ı digital.Message'a çevirir (ham MIME varsa önce o ayrıştırılır, alanlar eksikleri doldurur).
func buildMessage(p inboundPayload, raw []byte) *digital.Message {
	m := &digital.Message{}
	if len(raw) > 0 {
		if parsed, err := digital.ParseEML(raw); err == nil {
			m = parsed
		}
	}
	// JSON/form alanları ham RFC 2047 olabilir (ör. Worker'ın boyut bildirimi başlıkları aynen iletir).
	if m.Subject == "" {
		m.Subject = digital.DecodeHeader(p.Subject)
	}
	if m.From == "" {
		m.From = digital.DecodeHeader(p.From)
	}
	if m.MessageID == "" {
		m.MessageID = p.MessageID
	}
	if strings.TrimSpace(m.Text) == "" {
		m.Text = p.Text
	}
	if strings.TrimSpace(m.HTML) == "" {
		m.HTML = p.HTML
	}
	for _, a := range p.Attachments {
		data, err := base64.StdEncoding.DecodeString(a.ContentBase64)
		if err != nil || len(data) == 0 {
			continue
		}
		name := strings.ToLower(a.Filename)
		ct := strings.ToLower(a.ContentType)
		switch {
		case strings.Contains(ct, "pdf") || strings.HasSuffix(name, ".pdf"):
			if len(m.PDFs) < 5 {
				m.PDFs = append(m.PDFs, digital.Attachment{Name: a.Filename, Data: data})
			}
		case strings.Contains(ct, "zip") || strings.HasSuffix(name, ".zip"):
			m.PDFs = append(m.PDFs, digital.ExtractZipPDFs(data, 5)...)
			m.XMLs = append(m.XMLs, digital.ExtractZipXMLs(data, 5)...)
		case strings.Contains(ct, "xml") || strings.HasSuffix(name, ".xml"):
			if len(m.XMLs) < 5 && len(data) <= 5<<20 {
				m.XMLs = append(m.XMLs, digital.Attachment{Name: a.Filename, Data: data})
			}
		}
	}
	return m
}

// recipientCandidates alias çözümü için adres adaylarını öncelik sırasıyla verir: zarf alıcısı, sonra başlıklar.
func recipientCandidates(p inboundPayload, m *digital.Message) []string {
	var out []string
	for _, group := range []flexStrings{p.Envelope.To, p.Recipient, p.To} {
		out = append(out, group...)
	}
	out = append(out, m.Recipients...)
	return out
}

// lookupAlias adaylar arasında INBOUND_EMAIL_DOMAIN'e ait ilk bilinen alias'ı bulur (+tag ve büyük/küçük harf toleranslı).
func (h *handler) lookupAlias(cands []string) (userID int64, profile sql.NullInt64, alias string, paused bool, err error) {
	for _, raw := range cands {
		for _, piece := range strings.FieldsFunc(raw, func(r rune) bool { return r == ',' || r == ';' }) {
			addr := strings.ToLower(strings.TrimSpace(piece))
			if a, perr := mail.ParseAddress(piece); perr == nil {
				addr = strings.ToLower(a.Address)
			}
			at := strings.LastIndex(addr, "@")
			if at <= 0 || addr[at+1:] != h.inbound.Domain {
				continue
			}
			local := addr[:at]
			if i := strings.IndexByte(local, '+'); i >= 0 {
				local = local[:i]
			}
			e := h.db.QueryRow(`SELECT user_id, profile_id, paused FROM expense.inbound_aliases WHERE alias = $1`, local).Scan(&userID, &profile, &paused)
			if errors.Is(e, sql.ErrNoRows) {
				continue
			}
			return userID, profile, local, paused, e
		}
	}
	return 0, sql.NullInt64{}, "", false, sql.ErrNoRows
}

// finishInbound webhook sonucunu iki yere TEK çağrıyla yazar: alias durumu (`last_status`, `bump` ise `last_received_at`
// de) ve aktarım geçmişi. Alias geçerli her mail (kaydedildi / yok sayıldı / hata) için bump=true; yalnız Gmail
// yönlendirme onay maili (fiş aktarımı değil) bump=false kullanır.
func (h *handler) finishInbound(userID int64, from, subject, lastStatus, histStatus, reason string, expenseID int64, bump bool) {
	h.setInboundStatus(userID, lastStatus, bump)
	h.recordInboundHistory(userID, from, subject, histStatus, reason, expenseID)
}

// failureReason geçmişteki `failed` satırı için "<kod>: <gerçek hata>" metni (≤160 rune; kontrol karakterleri temizlenir).
func failureReason(code string, cause error) string {
	if cause == nil {
		return code
	}
	msg := cleanHistoryField(cause.Error())
	if r := []rune(msg); len(r) > 160 {
		msg = string(r[:160])
	}
	return code + ": " + msg
}

// recordEarlyReject gövdesi okunamayan (413 / bozuk) istekte zarf alıcısı (?rcpt=) geçerli bir alias'a aitse geçmişe
// ve last_status'a "ignored:<reason>" yazar. Gönderen/konu bilinmez (gövde okunmadı). Duraklatılmış adreste yazılmaz.
func (h *handler) recordEarlyReject(rcpt, reason string) {
	if strings.TrimSpace(rcpt) == "" {
		return
	}
	userID, _, _, paused, err := h.lookupAlias([]string{rcpt})
	if err != nil || paused {
		return
	}
	log.Printf("inbound: user %d: request rejected before parse (%s)", userID, reason)
	h.finishInbound(userID, "", "", "ignored:"+reason, historyIgnored, reason, 0, true)
}

func (h *handler) setInboundStatus(userID int64, status string, received bool) {
	q := `UPDATE expense.inbound_aliases SET last_status = $2 WHERE user_id = $1`
	if received {
		q = `UPDATE expense.inbound_aliases SET last_status = $2, last_received_at = now() WHERE user_id = $1`
	}
	if _, err := h.db.Exec(q, userID, status); err != nil {
		log.Printf("inbound: status update failed for user %d: %v", userID, err)
	}
}

// inboundEmail: POST /webhooks/inbound-email
func (h *handler) inboundEmail(c *gin.Context) {
	secret := c.GetHeader("X-Webhook-Secret")
	if h.inbound.Secret == "" || subtle.ConstantTimeCompare([]byte(secret), []byte(h.inbound.Secret)) != 1 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized", "code": "unauthorized"})
		return
	}
	ignored := func(reason string) { c.JSON(http.StatusOK, gin.H{"status": "ignored", "reason": reason}) }
	if !h.inbound.enabled() {
		ignored("inbound_not_configured")
		return
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, h.inbound.maxBytes())
	p, err := h.readInbound(c)
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			// Gövde okunamadı ama zarf alıcısı ?rcpt= ile biliniyorsa kullanıcı geçmişinde nedenini görsün.
			h.recordEarlyReject(c.Query("rcpt"), rejectedTooLarge)
			c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "request too large"})
			return
		}
		h.recordEarlyReject(c.Query("rcpt"), "unreadable_payload")
		ignored("unreadable_payload")
		return
	}
	raw := p.rawMIME()
	msg := buildMessage(p, raw)

	userID, profile, alias, paused, err := h.lookupAlias(recipientCandidates(p, msg))
	if errors.Is(err, sql.ErrNoRows) {
		ignored("unknown_alias") // alias sızdırmamak için sağlayıcıya her zaman 200
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	// Aktarım geçmişi: alias çözüldükten sonraki her çıkış tek satır kaydeder (gövde/ek saklanmaz).
	// finish: alias geçerliyse sonucu (saved / ignored / failed fark etmez) HEM `inbound_aliases.last_status +
	// last_received_at` HEM geçmişe tek yerden yazar; ikisi asla ayrışmaz.
	finish := func(lastStatus, histStatus, reason string, expenseID int64) {
		h.finishInbound(userID, msg.From, msg.Subject, lastStatus, histStatus, reason, expenseID, true)
	}
	skip := func(reason string) {
		finish("ignored:"+reason, historyIgnored, reason, 0)
		ignored(reason)
	}
	// fail: gerçek hatayı loglar ve (kısaltılmış) geçmiş `reason`ına yazar; last_status yalnız kısa kod taşır.
	fail := func(code string, cause error) {
		log.Printf("inbound: user %d: %s: %v", userID, code, cause)
		finish("failed:"+code, historyFailed, failureReason(code, cause), 0)
		serverError(c)
	}
	// Duraklatılmış adres: hiçbir şey işlenmez (rate limiter ve Gmail onay tespitinden önce). Mail "son aktarım" sayılmaz
	// (bump=false), ama geçmişte "paused" nedeniyle görünür.
	if paused {
		h.finishInbound(userID, msg.From, msg.Subject, "ignored:paused", historyIgnored, "paused", 0, false)
		ignored("paused")
		return
	}
	// Yönlendiricinin gövdesiz boyut bildirimi (Worker maili INBOUND_MAX_BYTES'i aştığı için göndermedi): fiş yok,
	// yalnız geçmişe "too_large". Rate limiter'dan önce: bildirim sayacı tüketmez.
	if p.Rejected == rejectedTooLarge {
		log.Printf("inbound: user %d: mail too large at forwarder (%d bytes)", userID, p.Size)
		skip(rejectedTooLarge)
		return
	}
	if !inboundLimiter.allow(alias, time.Now()) {
		log.Printf("inbound: alias rate limited (user %d)", userID)
		skip("rate_limited")
		return
	}

	// Gmail yönlendirme onayı: fiş DEĞİLDİR; kod/bağlantı saklanır, mobil istemci çeker.
	// Tutar/fiş ayrıştırmasından ÖNCE çalışır. Ham MIME (kodlu hâliyle) ve konu da kaynak olarak taranır.
	htmlText := digital.HTMLToText(msg.HTML)
	extra := []string{msg.Subject}
	if len(raw) > 0 {
		extra = append(extra, string(raw[:min(len(raw), gmailScanLimit)]))
	}
	if conf, ok := digital.DetectGmailConfirmation(msg.From, msg.Text, htmlText, msg.HTML, extra...); ok {
		if conf.Code == "" && conf.Link == "" {
			// Google'ın onay göndericisi ama kod/bağlantı okunamadı: fiş olarak denenmez, sessizce atlanır.
			log.Printf("inbound: user %d: gmail confirmation without readable code/link", userID)
			// Gmail onay maili fiş aktarımı DEĞİLDİR: last_received_at ilerlemez (kurulum bitmeden sihirbaz "Aktif" demesin).
			h.finishInbound(userID, msg.From, msg.Subject, "ignored:gmail_confirmation_unreadable", historyIgnored,
				"gmail_confirmation_unreadable", 0, false)
			ignored("gmail_confirmation_unreadable")
			return
		}
		log.Printf("inbound: user %d: gmail forwarding confirmation captured (code=%t link=%t)", userID, conf.Code != "", conf.Link != "")
		if err := h.saveConfirmation(userID, conf); err != nil {
			fail("confirmation_save", err)
			return
		}
		h.finishInbound(userID, msg.From, msg.Subject, "gmail_confirmation", historyIgnored, "gmail_confirmation", 0, false)
		c.JSON(http.StatusOK, gin.H{"status": "confirmation"})
		return
	}

	// Kaynak önceliği: UBL-TR XML eki > PDF metin katmanı > HTML gövde > düz metin. Mail tek fiş olarak kaydedilir;
	// XML okunamazsa sıradaki kaynağa düşülür.
	var (
		in     expenseInput
		ok     bool
		reason string
	)
	if inv := firstInvoice(msg); inv != nil {
		in, ok, reason, err = h.expenseFromInvoice(userID, inv, msg)
	} else {
		pdfFn := h.inbound.PDFText
		text, source := digital.ReceiptText(msg, pdfFn)
		if strings.TrimSpace(text) == "" {
			log.Printf("inbound: user %d: no usable receipt text (%s)", userID, source)
			skip(source)
			return
		}
		in, ok, reason, err = h.expenseFromEmail(userID, text, source, msg)
	}
	if err != nil {
		fail("parse_error", err)
		return
	}
	if !ok {
		log.Printf("inbound: user %d: not saved (%s)", userID, reason)
		skip(reason)
		return
	}

	var profileArg int64
	if profile.Valid {
		profileArg = profile.Int64
	}
	pid, found, err := h.resolveProfile(userID, profileArg)
	if err == nil && !found { // hedef profil silinmiş (SET NULL öncesi yarış): varsayılana düş
		pid, found, err = h.resolveProfile(userID, 0)
	}
	if err != nil || !found {
		if err == nil {
			err = errors.New("no profile available")
		}
		fail("profile_error", err)
		return
	}
	itemsJSON, _ := json.Marshal(itemsForStorage(in.Items))
	d, _ := time.Parse(dateLayout, in.Date)
	tx, err := h.db.Begin()
	if err != nil {
		fail("db_error", err)
		return
	}
	defer tx.Rollback()
	id, outcome, dup, err := writeExpense(tx, userID, pid, in.ClientUID, in, d, string(itemsJSON))
	if dup != "" {
		// Mükerrer: hata fırlatmadan logla ve kullanıcıya durum olarak yansıt.
		log.Printf("inbound: user %d: %s (existing expense %d)", userID, dup, id)
		// Geçmiş satırı mevcut fişe FK ile bağlanır: tx hâlâ o satırı kilitliyorsa (FOR UPDATE) ayrı bağlantıdaki
		// INSERT bekler ve kendi kendimizi kilitleriz. Önce işlemi bırak.
		_ = tx.Rollback()
		finish(dup, historyIgnored, dup, id)
		c.JSON(http.StatusOK, gin.H{"status": "duplicate", "reason": dup, "id": id})
		return
	}
	if err != nil {
		_ = tx.Rollback()
		if isFKViolation(err) {
			skip("unknown_category")
			return
		}
		fail("db_error", err)
		return
	}
	if outcome == writeCreated {
		if err := saveRules(tx, userID, collectRuleUpdates(in)); err != nil {
			_ = tx.Rollback() // fail() ayrı bağlantıdan yazar; açık tx kilitlerini önce bırak
			fail("db_error", err)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		fail("db_error", err)
		return
	}
	if outcome == writeSkipped {
		// Ayni icerik (onsozu atilmis ayni metin) daha once ice aktarilmis: ayni client_uid -> mukerrer.
		finish("duplicate", historyIgnored, "already_imported", id)
		c.JSON(http.StatusOK, gin.H{"status": "duplicate", "reason": "already_imported", "id": id})
		return
	}
	finish(outcome, historySaved, outcome, id)
	c.JSON(http.StatusOK, gin.H{"status": outcome, "id": id})
}

func (h *handler) saveConfirmation(userID int64, conf digital.GmailConfirmation) error {
	if _, err := h.db.Exec(`INSERT INTO expense.forwarding_confirmations (user_id, code, link) VALUES ($1, $2, NULLIF($3, ''))`, userID, conf.Code, conf.Link); err != nil {
		return err
	}
	_, err := h.db.Exec(
		`DELETE FROM expense.forwarding_confirmations WHERE user_id = $1 AND id NOT IN
		 (SELECT id FROM expense.forwarding_confirmations WHERE user_id = $1 ORDER BY received_at DESC, id DESC LIMIT $2)`, userID, maxConfirmationsKept)
	return err
}
