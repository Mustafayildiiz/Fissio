package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/base32"
	"errors"
	"net/http"
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

// ---- JWT'li uçlar -------------------------------------------------------------------------------------------------

type inboundInfo struct {
	Enabled        bool    `json:"enabled"`
	Address        string  `json:"address,omitempty"`
	ProfileID      *int64  `json:"profile_id,omitempty"`
	LastReceivedAt *string `json:"last_received_at,omitempty"`
	LastStatus     *string `json:"last_status,omitempty"`
	// Paused: kullanıcı aktarımı geçici durdurdu; gelen mailler fişe dönüşmez (geçmişe "paused" olarak yazılır).
	Paused bool `json:"paused,omitempty"`
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
	var paused bool
	err := h.db.QueryRow(`SELECT alias, profile_id, last_received_at, last_status, paused FROM expense.inbound_aliases WHERE user_id = $1`, userID).
		Scan(&alias, &profile, &last, &status, &paused)
	if err != nil {
		return inboundInfo{}, err
	}
	info := inboundInfo{Enabled: true, Address: h.inbound.address(alias), Paused: paused}
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
		_, err := h.db.Exec(`UPDATE expense.inbound_aliases SET alias = $2, last_received_at = NULL, last_status = NULL, paused = false WHERE user_id = $1`, userID, newAlias())
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

// POST /inbound-address/pause ve /resume: aktarımı geçici durdurur / sürdürür (idempotent). Adres ve geçmiş korunur.
func (h *handler) pauseInboundAddress(c *gin.Context)  { h.setInboundPaused(c, true) }
func (h *handler) resumeInboundAddress(c *gin.Context) { h.setInboundPaused(c, false) }

func (h *handler) setInboundPaused(c *gin.Context, paused bool) {
	if !h.inbound.enabled() {
		c.JSON(http.StatusOK, inboundInfo{Enabled: false})
		return
	}
	userID := c.GetInt64("userID")
	if _, err := h.ensureAlias(userID); err != nil {
		serverError(c)
		return
	}
	if _, err := h.db.Exec(`UPDATE expense.inbound_aliases SET paused = $2 WHERE user_id = $1`, userID, paused); err != nil {
		serverError(c)
		return
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
