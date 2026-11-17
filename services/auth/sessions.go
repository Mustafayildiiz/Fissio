package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"time"
)

var (
	errInvalidRefresh = errors.New("invalid refresh token")
	errSessionRevoked = errors.New("session revoked")
)

func newRefreshToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func hashRefresh(secret []byte, raw string) string {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(raw))
	return hex.EncodeToString(m.Sum(nil))
}

type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
	QueryRow(query string, args ...any) *sql.Row
}

// createSession yeni oturum acar ve ilk refresh token'i uretir.
func (h *handler) createSession(userID int64, device, platform, ip string) (sid, refresh string, err error) {
	if err = h.db.QueryRow(
		`INSERT INTO auth.sessions (user_id, device_name, platform, ip) VALUES ($1,$2,$3,$4) RETURNING id::text`,
		userID, device, platform, ip).Scan(&sid); err != nil {
		return
	}
	refresh, err = h.insertRefresh(h.db, sid)
	return
}

func (h *handler) insertRefresh(q execer, sid string) (string, error) {
	raw, err := newRefreshToken()
	if err != nil {
		return "", err
	}
	_, err = q.Exec(
		`INSERT INTO auth.refresh_tokens (session_id, token_hash, expires_at) VALUES ($1::uuid,$2, now() + $3 * interval '1 second')`,
		sid, hashRefresh(h.cfg.refreshSecret, raw), int64(refreshTTL.Seconds()))
	return raw, err
}

type tokenPair struct {
	Access    string
	Refresh   string
	ExpiresAt time.Time
	UserID    int64
	SID       string
}

// issueTokens oturum icin access token uretir.
func (h *handler) accessFor(userID int64, sid string) (string, time.Time, error) {
	return issueAccessToken(h.cfg.accessSecret, userID, sid, accessTTL)
}

// rotateRefresh refresh token'i tek kullanimlik olarak doner ve yeni cift uretir.
// Kullanilmis token grace suresi icindeyse (istemci yeni token'i kaydedemeden kapandi) yeni cift verilir;
// grace disinda yeniden kullanim calinti sayilir ve oturum iptal edilir.
func (h *handler) rotateRefresh(raw string) (tokenPair, error) {
	var tp tokenPair
	tx, err := h.db.Begin()
	if err != nil {
		return tp, err
	}
	defer tx.Rollback()

	var rtID int64
	var usedAt sql.NullTime
	var expired, revoked bool
	err = tx.QueryRow(
		`SELECT rt.id, rt.used_at, rt.expires_at < now(), s.revoked_at IS NOT NULL, s.id::text, s.user_id
		 FROM auth.refresh_tokens rt JOIN auth.sessions s ON s.id = rt.session_id
		 WHERE rt.token_hash = $1 FOR UPDATE OF rt`, hashRefresh(h.cfg.refreshSecret, raw)).
		Scan(&rtID, &usedAt, &expired, &revoked, &tp.SID, &tp.UserID)
	if errors.Is(err, sql.ErrNoRows) {
		return tp, errInvalidRefresh
	}
	if err != nil {
		return tp, err
	}
	if revoked {
		return tp, errSessionRevoked
	}
	if expired {
		return tp, errInvalidRefresh
	}
	if usedAt.Valid && time.Since(usedAt.Time) > refreshGrace {
		// Calinti suphesi: oturumu iptal et (commit gerekir).
		if _, err := tx.Exec(`UPDATE auth.sessions SET revoked_at = now() WHERE id = $1::uuid AND revoked_at IS NULL`, tp.SID); err != nil {
			return tp, err
		}
		if err := tx.Commit(); err != nil {
			return tp, err
		}
		return tp, errSessionRevoked
	}
	// Oturumdaki tum kullanilmamis token'lari kapat; yalniz yeni cift gecerli kalsin.
	if _, err := tx.Exec(`UPDATE auth.refresh_tokens SET used_at = now() WHERE session_id = $1::uuid AND used_at IS NULL`, tp.SID); err != nil {
		return tp, err
	}
	tp.Refresh, err = h.insertRefresh(tx, tp.SID)
	if err != nil {
		return tp, err
	}
	if _, err := tx.Exec(`UPDATE auth.sessions SET last_active_at = now() WHERE id = $1::uuid`, tp.SID); err != nil {
		return tp, err
	}
	if err := tx.Commit(); err != nil {
		return tp, err
	}
	tp.Access, tp.ExpiresAt, err = h.accessFor(tp.UserID, tp.SID)
	return tp, err
}

// sessionAlive oturum var ve iptal edilmemis mi.
func (h *handler) sessionAlive(sid string) (bool, error) {
	var ok bool
	err := h.db.QueryRow(
		`SELECT EXISTS (SELECT 1 FROM auth.sessions WHERE id = $1::uuid AND revoked_at IS NULL)`, sid).Scan(&ok)
	return ok, err
}
