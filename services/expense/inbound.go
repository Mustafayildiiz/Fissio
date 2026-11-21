package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/mail"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"fissio/expense/internal/digital"
	"fissio/expense/internal/receiptparse"
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

var aliasEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// newAlias 80 bit rastgele, küçük harfli 16 karakterlik takma ad üretir.
func newAlias() string {
	b := make([]byte, 10)
	_, _ = rand.Read(b)
	return strings.ToLower(aliasEncoding.EncodeToString(b))
}

// ---- JWT'li uçlar -------------------------------------------------------------------------------------------------

type inboundInfo struct {
	Enabled        bool    `json:"enabled"`
	Address        string  `json:"address,omitempty"`
	ProfileID      *int64  `json:"profile_id,omitempty"`
	LastReceivedAt *string `json:"last_received_at,omitempty"`
	LastStatus     *string `json:"last_status,omitempty"`
}

// ensureAlias kullanıcının takma adını (yoksa üreterek) döndürür.
func (h *handler) ensureAlias(userID int64) (inboundInfo, error) {
	for attempt := 0; attempt < 5; attempt++ {
		if _, err := h.db.Exec(`INSERT INTO expense.inbound_aliases (user_id, alias) VALUES ($1, $2) ON CONFLICT (user_id) DO NOTHING`, userID, newAlias()); err != nil {
			if isUniqueViolation(err) {
				continue // alias çakışması (≈0): yeniden dene
			}
			return inboundInfo{}, err
		}
		break
	}
	return h.loadInbound(userID)
}

func (h *handler) loadInbound(userID int64) (inboundInfo, error) {
	var alias string
	var profile sql.NullInt64
	var last sql.NullTime
	var status sql.NullString
	err := h.db.QueryRow(`SELECT alias, profile_id, last_received_at, last_status FROM expense.inbound_aliases WHERE user_id = $1`, userID).
		Scan(&alias, &profile, &last, &status)
	if err != nil {
		return inboundInfo{}, err
	}
	info := inboundInfo{Enabled: true, Address: h.inbound.address(alias)}
	if profile.Valid {
		info.ProfileID = &profile.Int64
	}
	if last.Valid {
		s := formatUpdatedAt(last.Time)
		info.LastReceivedAt = &s
	}
	if status.Valid {
		info.LastStatus = &status.String
	}
	return info, nil
}

// GET /inbound-address
func (h *handler) getInboundAddress(c *gin.Context) {
	if !h.inbound.enabled() {
		c.JSON(http.StatusOK, inboundInfo{Enabled: false})
		return
	}
	info, err := h.ensureAlias(c.GetInt64("userID"))
	if err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, info)
}

// PUT /inbound-address {profile_id}: aktarılan fişlerin düşeceği profil (0/yok = en eski/varsayılan profil).
func (h *handler) putInboundAddress(c *gin.Context) {
	if !h.inbound.enabled() {
		c.JSON(http.StatusOK, inboundInfo{Enabled: false})
		return
	}
	var in struct {
		ProfileID int64 `json:"profile_id"`
	}
	if err := c.ShouldBindJSON(&in); err != nil || in.ProfileID < 0 {
		badRequest(c, "invalid request body")
		return
	}
	userID := c.GetInt64("userID")
	var arg any
	if in.ProfileID > 0 {
		pid, found, err := h.resolveProfile(userID, in.ProfileID)
		if err != nil {
			serverError(c)
			return
		}
		if !found {
			c.JSON(http.StatusNotFound, gin.H{"error": "profile not found"})
			return
		}
		arg = pid
	}
	if _, err := h.ensureAlias(userID); err != nil {
		serverError(c)
		return
	}
	if _, err := h.db.Exec(`UPDATE expense.inbound_aliases SET profile_id = $2 WHERE user_id = $1`, userID, arg); err != nil {
		serverError(c)
		return
	}
	h.getInboundAddress(c)
}

// POST /inbound-address/rotate: yeni takma ad (eskisi hemen geçersiz olur; yanlışlıkla sızan adres için).
func (h *handler) rotateInboundAddress(c *gin.Context) {
	if !h.inbound.enabled() {
		c.JSON(http.StatusOK, inboundInfo{Enabled: false})
		return
	}
	userID := c.GetInt64("userID")
	if _, err := h.ensureAlias(userID); err != nil {
		serverError(c)
		return
	}
	for attempt := 0; attempt < 5; attempt++ {
		_, err := h.db.Exec(`UPDATE expense.inbound_aliases SET alias = $2, last_received_at = NULL, last_status = NULL WHERE user_id = $1`, userID, newAlias())
		if isUniqueViolation(err) {
			continue
		}
		if err != nil {
			serverError(c)
			return
		}
		break
	}
	h.getInboundAddress(c)
}

// GET /inbound-address/confirmation: son 24 saatteki Gmail yönlendirme onayı ({code, link, received_at}) ya da 204.
func (h *handler) getForwardingConfirmation(c *gin.Context) {
	var code string
	var link sql.NullString
	var at time.Time
	err := h.db.QueryRow(
		`SELECT code, link, received_at FROM expense.forwarding_confirmations
		 WHERE user_id = $1 AND received_at > now() - make_interval(hours => $2)
		 ORDER BY received_at DESC, id DESC LIMIT 1`, c.GetInt64("userID"), confirmationTTLHours).Scan(&code, &link, &at)
	if errors.Is(err, sql.ErrNoRows) {
		c.Status(http.StatusNoContent)
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	out := gin.H{"received_at": formatUpdatedAt(at)}
	if code != "" { // kodsuz onayda yalnızca link döner
		out["code"] = code
	}
	if link.Valid && link.String != "" {
		out["link"] = link.String
	}
	c.JSON(http.StatusOK, out)
}

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
		p.Raw = string(b)
		if r := c.Query("rcpt"); r != "" {
			p.Recipient = flexStrings{r}
		}
		return p, err
	}
}

// buildMessage payload'ı digital.Message'a çevirir (ham MIME varsa önce o ayrıştırılır, alanlar eksikleri doldurur).
func buildMessage(p inboundPayload) *digital.Message {
	m := &digital.Message{}
	raw := []byte(p.Raw)
	if p.RawBase64 != "" {
		if b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(p.RawBase64)); err == nil {
			raw = b
		}
	}
	if len(raw) > 0 {
		if parsed, err := digital.ParseEML(raw); err == nil {
			m = parsed
		}
	}
	if m.Subject == "" {
		m.Subject = p.Subject
	}
	if m.From == "" {
		m.From = p.From
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
			m.PDFs = append(m.PDFs, digital.Attachment{Name: a.Filename, Data: data})
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
func (h *handler) lookupAlias(cands []string) (userID int64, profile sql.NullInt64, alias string, err error) {
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
			e := h.db.QueryRow(`SELECT user_id, profile_id FROM expense.inbound_aliases WHERE alias = $1`, local).Scan(&userID, &profile)
			if errors.Is(e, sql.ErrNoRows) {
				continue
			}
			return userID, profile, local, e
		}
	}
	return 0, sql.NullInt64{}, "", sql.ErrNoRows
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
			c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "request too large"})
			return
		}
		ignored("unreadable_payload")
		return
	}
	msg := buildMessage(p)

	userID, profile, alias, err := h.lookupAlias(recipientCandidates(p, msg))
	if errors.Is(err, sql.ErrNoRows) {
		ignored("unknown_alias") // alias sızdırmamak için sağlayıcıya her zaman 200
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	// Aktarım geçmişi: alias çözüldükten sonraki her çıkış tek satır kaydeder (gövde/ek saklanmaz).
	skip := func(reason string, expenseID int64) {
		h.recordInboundHistory(userID, msg.From, msg.Subject, historyIgnored, reason, expenseID)
		ignored(reason)
	}
	fail := func(reason string) {
		h.recordInboundHistory(userID, msg.From, msg.Subject, historyFailed, reason, 0)
		serverError(c)
	}
	if !inboundLimiter.allow(alias, time.Now()) {
		log.Printf("inbound: alias rate limited (user %d)", userID)
		h.setInboundStatus(userID, "ignored:rate_limited", false)
		skip("rate_limited", 0)
		return
	}

	// Gmail yönlendirme onayı: fiş DEĞİLDİR; kod/bağlantı saklanır, mobil istemci çeker.
	// Tutar/fiş ayrıştırmasından ÖNCE çalışır. Ham MIME (kodlu hâliyle) ve konu da kaynak olarak taranır.
	htmlText := digital.HTMLToText(msg.HTML)
	extra := []string{msg.Subject, p.Raw}
	if p.RawBase64 != "" {
		if b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(p.RawBase64)); err == nil {
			extra = append(extra, string(b))
		}
	}
	if conf, ok := digital.DetectGmailConfirmation(msg.From, msg.Text, htmlText, msg.HTML, extra...); ok {
		if conf.Code == "" && conf.Link == "" {
			// Google'ın onay göndericisi ama kod/bağlantı okunamadı: fiş olarak denenmez, sessizce atlanır.
			log.Printf("inbound: user %d: gmail confirmation without readable code/link", userID)
			h.setInboundStatus(userID, "ignored:gmail_confirmation_unreadable", false)
			skip("gmail_confirmation_unreadable", 0)
			return
		}
		log.Printf("inbound: user %d: gmail forwarding confirmation captured (code=%t link=%t)", userID, conf.Code != "", conf.Link != "")
		if err := h.saveConfirmation(userID, conf); err != nil {
			fail("confirmation_save")
			return
		}
		h.setInboundStatus(userID, "gmail_confirmation", false)
		h.recordInboundHistory(userID, msg.From, msg.Subject, historyIgnored, "gmail_confirmation", 0)
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
			h.setInboundStatus(userID, "ignored:"+source, false)
			skip(source, 0)
			return
		}
		in, ok, reason, err = h.expenseFromEmail(userID, text, source, msg)
	}
	if err != nil {
		fail("parse_error")
		return
	}
	if !ok {
		log.Printf("inbound: user %d: not saved (%s)", userID, reason)
		h.setInboundStatus(userID, "ignored:"+reason, false)
		skip(reason, 0)
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
		fail("profile_error")
		return
	}
	itemsJSON, _ := json.Marshal(itemsForStorage(in.Items))
	d, _ := time.Parse(dateLayout, in.Date)
	tx, err := h.db.Begin()
	if err != nil {
		fail("db_error")
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
		h.setInboundStatus(userID, dup, true)
		h.recordInboundHistory(userID, msg.From, msg.Subject, historyIgnored, dup, id)
		c.JSON(http.StatusOK, gin.H{"status": "duplicate", "reason": dup, "id": id})
		return
	}
	if err != nil {
		_ = tx.Rollback()
		if isFKViolation(err) {
			h.setInboundStatus(userID, "ignored:unknown_category", false)
			skip("unknown_category", 0)
			return
		}
		fail("db_error")
		return
	}
	if outcome == writeCreated {
		if err := saveRules(tx, userID, collectRuleUpdates(in)); err != nil {
			fail("db_error")
			return
		}
	}
	if err := tx.Commit(); err != nil {
		fail("db_error")
		return
	}
	if outcome == writeSkipped {
		// Ayni icerik (onsozu atilmis ayni metin) daha once ice aktarilmis: ayni client_uid -> mukerrer.
		h.setInboundStatus(userID, "duplicate", true)
		h.recordInboundHistory(userID, msg.From, msg.Subject, historyIgnored, "already_imported", id)
		c.JSON(http.StatusOK, gin.H{"status": "duplicate", "reason": "already_imported", "id": id})
		return
	}
	h.setInboundStatus(userID, outcome, true)
	h.recordInboundHistory(userID, msg.From, msg.Subject, historySaved, outcome, id)
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

// expenseFromEmail e-posta metnini ayrıştırıp kayda hazır expenseInput'a çevirir. ok=false: kaydedilemez (reason).
func (h *handler) expenseFromEmail(userID int64, text, source string, msg *digital.Message) (expenseInput, bool, string, error) {
	cats, err := h.loadCategories()
	if err != nil {
		return expenseInput{}, false, "", err
	}
	rules, err := loadRules(h.db, userID)
	if err != nil {
		return expenseInput{}, false, "", err
	}
	if len(text) > 20000 {
		text = text[:20000]
	}
	parsed := receiptparse.ParseWith(text, cats, time.Now(), receiptparse.ParseOptions{Rules: rules})
	if parsed.Amount == nil || *parsed.Amount <= 0 {
		return expenseInput{}, false, "no_amount", nil
	}
	// Platform sipariş özetleri (Yemeksepeti, Getir, Trendyol Yemek…): HTML tablosundaki ad/adet/satır tutarı genel
	// metin ayrıştırmasından daha doğruysa (kalem bulunamadı ya da toplam tutmuyor) tablo kalemleri kullanılır.
	if source == digital.SourceHTML {
		if tbl := digital.HTMLTableItems(msg.HTML); preferTableItems(parsed.Items, tbl, *parsed.Amount) {
			items := make([]receiptparse.Item, 0, len(tbl))
			for _, it := range tbl {
				items = append(items, receiptparse.Item{Name: it.DisplayName(), Amount: float64(it.AmountCents) / 100})
			}
			parsed.Items = receiptparse.CategorizeStructured(parsed.Merchant, *parsed.Amount, items, parsed.Date, cats,
				receiptparse.ParseOptions{Rules: rules}).Items
		}
	}
	date := time.Now().UTC().Format(dateLayout)
	switch {
	case parsed.Date != nil:
		date = *parsed.Date
	case !msg.Date.IsZero():
		date = msg.Date.UTC().Format(dateLayout)
	}
	catID := parsed.CategoryID
	if catID == 0 {
		for _, c := range cats {
			if c.Name == "Diğer" {
				catID = c.ID
			}
		}
	}
	merchant := strings.TrimSpace(parsed.Merchant)
	if merchant == "" {
		merchant = displayName(msg.From)
	}
	if merchant == "" {
		merchant = "E-posta fişi"
	}
	engine := "email"
	if source == digital.SourcePDF {
		engine = "pdf"
	}
	docNo := digital.ExtractDocumentNo(text)
	orderID := digital.ExtractOrderID(text)
	in := expenseInput{
		Merchant:   merchant,
		Amount:     *parsed.Amount,
		Date:       date,
		CategoryID: catID,
		Note:       emailNote(msg.Subject),
		Items:      itemsOrEmpty(parsed.Items),
		ClientUID:  mailClientUID(userID, text),
		OcrEngine:  &engine,
	}
	if docNo != "" {
		in.DocumentNo = &docNo
	}
	if orderID != "" {
		in.OrderID = &orderID
	}
	if _, msg := in.validate(); msg != "" {
		return expenseInput{}, false, "invalid:" + msg, nil
	}
	return in, true, "", nil
}

func itemsOrEmpty(items []expenseItem) []expenseItem {
	if items == nil {
		return []expenseItem{}
	}
	return items
}

func emailNote(subject string) string {
	s := strings.TrimSpace(subject)
	if s == "" {
		return ""
	}
	r := []rune("E-posta: " + s)
	if len(r) > 200 {
		r = r[:200]
	}
	return string(r)
}

func displayName(from string) string {
	if a, err := mail.ParseAddress(from); err == nil && strings.TrimSpace(a.Name) != "" {
		return strings.TrimSpace(a.Name)
	}
	return ""
}

// mailClientUID: aynı mail iki kez iletilse bile (yeni Message-ID) aynı kayda çözülsün diye ÖNSÖZÜ ATILMIŞ gövde metninden
// türetilir (boşluk/harf farkından bağımsız).
func mailClientUID(userID int64, text string) string {
	canon := strings.Join(strings.Fields(receiptparse.FoldTR(text)), " ")
	sum := sha256.Sum256([]byte(strconv.FormatInt(userID, 10) + "|" + canon))
	return "mail-" + hex.EncodeToString(sum[:8])
}
