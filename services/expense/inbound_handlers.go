package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/base32"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

var aliasEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// newAlias 80 bit rastgele, küçük harfli 16 karakterlik takma ad üretir.
func newAlias() string {
	b := make([]byte, 10)
	_, _ = rand.Read(b)
	return strings.ToLower(aliasEncoding.EncodeToString(b))
}

/// ---- JWT'li uçlar -------------------------------------------------------------------------------------------------
//
// Her profilin KENDİ adresi vardır: uçlar `?profile_uid=<client_uid>` (ya da `?profile_id=<id>`) ile profili seçer;
// ikisi de yoksa kullanıcının varsayılan (en eski) profili. Sunucu istemcinin "aktif" profilini bilmez.

type inboundInfo struct {
	Enabled        bool    `json:"enabled"`
	Address        string  `json:"address,omitempty"`
	ProfileID      *int64  `json:"profile_id,omitempty"`
	ProfileUID     string  `json:"profile_uid,omitempty"`
	ProfileName    string  `json:"profile_name,omitempty"`
	LastReceivedAt *string `json:"last_received_at,omitempty"`
	LastStatus     *string `json:"last_status,omitempty"`
	// Paused: kullanıcı aktarımı geçici durdurdu; gelen mailler fişe dönüşmez (geçmişe "paused" olarak yazılır).
	Paused bool `json:"paused,omitempty"`
}

// inboundProfile isteğin hedef profilini çözer. Öncelik: ?profile_uid= (client_uid) > ?profile_id= > bodyID > varsayılan.
// Başkasının / olmayan profil 404 `profile_not_found`; hatalı sayı 400. ok=false ise yanıt yazılmıştır.
func (h *handler) inboundProfile(c *gin.Context, bodyID int64) (int64, bool) {
	userID := c.GetInt64("userID")
	if uid := strings.TrimSpace(c.Query("profile_uid")); uid != "" {
		var pid int64
		err := h.db.QueryRow(`SELECT id FROM expense.profiles WHERE user_id = $1 AND client_uid = $2`, userID, uid).Scan(&pid)
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "profile not found", "code": codeProfileNotFound})
			return 0, false
		}
		if err != nil {
			serverError(c)
			return 0, false
		}
		return pid, true
	}
	id := bodyID
	if v := strings.TrimSpace(c.Query("profile_id")); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			badRequest(c, "invalid profile_id")
			return 0, false
		}
		id = n
	}
	pid, found, err := h.resolveProfile(userID, id)
	if err != nil {
		serverError(c)
		return 0, false
	}
	if !found {
		c.JSON(http.StatusNotFound, gin.H{"error": "profile not found", "code": codeProfileNotFound})
		return 0, false
	}
	return pid, true
}

// ensureAlias profilin takma adını (yoksa üreterek) döndürür.
func (h *handler) ensureAlias(userID, profileID int64) (inboundInfo, error) {
	for attempt := 0; attempt < 5; attempt++ {
		if _, err := h.db.Exec(`INSERT INTO expense.inbound_aliases (user_id, profile_id, alias) VALUES ($1, $2, $3)
			ON CONFLICT (user_id, profile_id) DO NOTHING`, userID, profileID, newAlias()); err != nil {
			if isUniqueViolation(err) {
				continue // alias çakışması (≈0): yeniden dene
			}
			return inboundInfo{}, err
		}
		break
	}
	return h.loadInbound(userID, profileID)
}

func (h *handler) loadInbound(userID, profileID int64) (inboundInfo, error) {
	var alias, puid, pname string
	var last sql.NullTime
	var status sql.NullString
	var paused bool
	err := h.db.QueryRow(`SELECT a.alias, p.client_uid, p.name, a.last_received_at, a.last_status, a.paused
		FROM expense.inbound_aliases a JOIN expense.profiles p ON p.id = a.profile_id
		WHERE a.user_id = $1 AND a.profile_id = $2`, userID, profileID).
		Scan(&alias, &puid, &pname, &last, &status, &paused)
	if err != nil {
		return inboundInfo{}, err
	}
	pid := profileID
	info := inboundInfo{Enabled: true, Address: h.inbound.address(alias), ProfileID: &pid, ProfileUID: puid,
		ProfileName: pname, Paused: paused}
	if last.Valid {
		s := formatUpdatedAt(last.Time)
		info.LastReceivedAt = &s
	}
	if status.Valid {
		info.LastStatus = &status.String
	}
	return info, nil
}

func (h *handler) respondInbound(c *gin.Context, userID, profileID int64) {
	info, err := h.ensureAlias(userID, profileID)
	if err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, info)
}

// GET /inbound-address?profile_uid=: profilin adresi (yoksa üretilir).
func (h *handler) getInboundAddress(c *gin.Context) {
	if !h.inbound.enabled() {
		c.JSON(http.StatusOK, inboundInfo{Enabled: false})
		return
	}
	pid, ok := h.inboundProfile(c, 0)
	if !ok {
		return
	}
	h.respondInbound(c, c.GetInt64("userID"), pid)
}

// PUT /inbound-address?profile_uid= (gövde isteğe bağlı; eski istemciler {profile_id} gönderir): profilin adresini
// oluşturur/döndürür. Artık "fişlerin düşeceği profili değiştir" anlamı YOKTUR: her profilin kendi adresi vardır.
func (h *handler) putInboundAddress(c *gin.Context) {
	if !h.inbound.enabled() {
		c.JSON(http.StatusOK, inboundInfo{Enabled: false})
		return
	}
	var in struct {
		ProfileID int64 `json:"profile_id"`
	}
	if c.Request.ContentLength != 0 {
		if err := c.ShouldBindJSON(&in); err != nil && !errors.Is(err, io.EOF) {
			badRequest(c, "invalid request body")
			return
		}
		if in.ProfileID < 0 {
			badRequest(c, "invalid request body")
			return
		}
	}
	pid, ok := h.inboundProfile(c, in.ProfileID)
	if !ok {
		return
	}
	h.respondInbound(c, c.GetInt64("userID"), pid)
}

// POST /inbound-address/rotate?profile_uid=: profile yeni takma ad (eskisi hemen geçersiz olur; sızan adres için).
func (h *handler) rotateInboundAddress(c *gin.Context) {
	if !h.inbound.enabled() {
		c.JSON(http.StatusOK, inboundInfo{Enabled: false})
		return
	}
	pid, ok := h.inboundProfile(c, 0)
	if !ok {
		return
	}
	userID := c.GetInt64("userID")
	if _, err := h.ensureAlias(userID, pid); err != nil {
		serverError(c)
		return
	}
	rotated := false
	for attempt := 0; attempt < 5 && !rotated; attempt++ {
		// Takma ad değişimi ve eski adrese ait Gmail onaylarının silinmesi tek işlemde: eski adresin kodu/bağlantısı
		// sihirbaz yeniden açıldığında (24 saat içinde) görünmemeli. Yalnız BU profilin onayları silinir.
		tx, err := h.db.Begin()
		if err != nil {
			serverError(c)
			return
		}
		_, err = tx.Exec(`UPDATE expense.inbound_aliases SET alias = $3, last_received_at = NULL, last_status = NULL, paused = false
			WHERE user_id = $1 AND profile_id = $2`, userID, pid, newAlias())
		if err == nil {
			_, err = tx.Exec(`DELETE FROM expense.forwarding_confirmations WHERE user_id = $1 AND profile_id = $2`, userID, pid)
		}
		if err == nil {
			err = tx.Commit()
		} else {
			_ = tx.Rollback()
		}
		if isUniqueViolation(err) {
			continue
		}
		if err != nil {
			serverError(c)
			return
		}
		rotated = true
	}
	if !rotated { // 5 çakışma: eski adresle sessizce 200 dönme
		serverError(c)
		return
	}
	h.respondInbound(c, userID, pid)
}

// POST /inbound-address/pause ve /resume?profile_uid=: profilin aktarımını geçici durdurur / sürdürür (idempotent).
// Adres ve geçmiş korunur.
func (h *handler) pauseInboundAddress(c *gin.Context)  { h.setInboundPaused(c, true) }
func (h *handler) resumeInboundAddress(c *gin.Context) { h.setInboundPaused(c, false) }

func (h *handler) setInboundPaused(c *gin.Context, paused bool) {
	if !h.inbound.enabled() {
		c.JSON(http.StatusOK, inboundInfo{Enabled: false})
		return
	}
	pid, ok := h.inboundProfile(c, 0)
	if !ok {
		return
	}
	userID := c.GetInt64("userID")
	if _, err := h.ensureAlias(userID, pid); err != nil {
		serverError(c)
		return
	}
	if _, err := h.db.Exec(`UPDATE expense.inbound_aliases SET paused = $3 WHERE user_id = $1 AND profile_id = $2`, userID, pid, paused); err != nil {
		serverError(c)
		return
	}
	h.respondInbound(c, userID, pid)
}

// GET /inbound-address/confirmation?profile_uid=: profilin son 24 saatteki Gmail yönlendirme onayı
// ({code, link, received_at}) ya da 204.
func (h *handler) getForwardingConfirmation(c *gin.Context) {
	pid, ok := h.inboundProfile(c, 0)
	if !ok {
		return
	}
	var code string
	var link sql.NullString
	var at time.Time
	err := h.db.QueryRow(
		`SELECT code, link, received_at FROM expense.forwarding_confirmations
		 WHERE user_id = $1 AND profile_id = $2 AND received_at > now() - make_interval(hours => $3)
		 ORDER BY received_at DESC, id DESC LIMIT 1`, c.GetInt64("userID"), pid, confirmationTTLHours).Scan(&code, &link, &at)
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

// ---- Kullanıcı düzeyi e-posta aktarım tercihleri ---------------------------------------------------------------------

type inboundSettings struct {
	// NotifyFailures: işlenemeyen/başarısız aktarımda hesabın kayıtlı e-postasına bilgilendirme (varsayılan açık).
	NotifyFailures bool `json:"notify_failures"`
}

func (h *handler) loadInboundSettings(userID int64) (inboundSettings, error) {
	out := inboundSettings{NotifyFailures: true}
	err := h.db.QueryRow(`SELECT notify_failures FROM expense.inbound_settings WHERE user_id = $1`, userID).Scan(&out.NotifyFailures)
	if errors.Is(err, sql.ErrNoRows) {
		return inboundSettings{NotifyFailures: true}, nil
	}
	return out, err
}

// GET /inbound-settings
func (h *handler) getInboundSettings(c *gin.Context) {
	s, err := h.loadInboundSettings(c.GetInt64("userID"))
	if err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, s)
}

// PUT /inbound-settings {notify_failures}
func (h *handler) putInboundSettings(c *gin.Context) {
	var in struct {
		NotifyFailures *bool `json:"notify_failures"`
	}
	if err := c.ShouldBindJSON(&in); err != nil || in.NotifyFailures == nil {
		badRequest(c, "notify_failures is required")
		return
	}
	userID := c.GetInt64("userID")
	if _, err := h.db.Exec(`INSERT INTO expense.inbound_settings (user_id, notify_failures) VALUES ($1, $2)
		ON CONFLICT (user_id) DO UPDATE SET notify_failures = EXCLUDED.notify_failures`, userID, *in.NotifyFailures); err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, inboundSettings{NotifyFailures: *in.NotifyFailures})
}
