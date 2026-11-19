package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

type sessionOut struct {
	ID           string    `json:"id"`
	DeviceName   string    `json:"device_name"`
	Platform     string    `json:"platform"`
	IP           string    `json:"ip"`
	CreatedAt    time.Time `json:"created_at"`
	LastActiveAt time.Time `json:"last_active_at"`
	Current      bool      `json:"current"`
}

func (h *handler) listSessions(c *gin.Context) {
	rows, err := h.db.Query(
		`SELECT id::text, device_name, platform, ip, created_at, last_active_at FROM auth.sessions
		 WHERE user_id=$1 AND revoked_at IS NULL ORDER BY last_active_at DESC`, c.GetInt64("userID"))
	if err != nil {
		internalErr(c, err)
		return
	}
	defer rows.Close()
	cur := c.GetString("sid")
	out := []sessionOut{}
	for rows.Next() {
		var s sessionOut
		if err := rows.Scan(&s.ID, &s.DeviceName, &s.Platform, &s.IP, &s.CreatedAt, &s.LastActiveAt); err != nil {
			internalErr(c, err)
			return
		}
		s.Current = s.ID == cur
		out = append(out, s)
	}
	c.JSON(http.StatusOK, out)
}

func (h *handler) revokeSession(c *gin.Context) {
	res, err := h.db.Exec(
		`UPDATE auth.sessions SET revoked_at = now() WHERE id::text = $1 AND user_id = $2 AND revoked_at IS NULL`,
		c.Param("id"), c.GetInt64("userID"))
	if err != nil {
		internalErr(c, err)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		fail(c, http.StatusNotFound, "not_found", "session not found")
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *handler) logoutAll(c *gin.Context) {
	if _, err := h.db.Exec(
		`UPDATE auth.sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL`, c.GetInt64("userID")); err != nil {
		internalErr(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

type deleteAccountInput struct {
	Password string `json:"password"`
}

// deleteAccount KVKK/GDPR: sifre onayiyla hesabi ve tum verilerini (profiller, fisler, gorseller, kurallar, oturumlar) kalici siler.
// expense verisi expense servisinin internal API'siyle silinir (auth expense semasina SQL atmaz).
func (h *handler) deleteAccount(c *gin.Context) {
	var in deleteAccountInput
	if err := c.ShouldBindJSON(&in); err != nil || in.Password == "" {
		fail(c, http.StatusBadRequest, "bad_request", "password required")
		return
	}
	id := c.GetInt64("userID")
	var email, hash string
	err := h.db.QueryRow(`SELECT email, password_hash FROM auth.users WHERE id=$1`, id).Scan(&email, &hash)
	if errors.Is(err, sql.ErrNoRows) {
		fail(c, http.StatusNotFound, "not_found", "user not found")
		return
	}
	if err != nil {
		internalErr(c, err)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(in.Password)) != nil {
		fail(c, http.StatusForbidden, "invalid_credentials", "invalid password")
		return
	}

	// 1) Hesabi "silinmekte" isaretle ve TUM oturumlari iptal et: yeni yazma/giris olmaz. Bu adim kalicidir; sonraki
	//    adimlar basarisiz olursa sweepDeletions (dakikada bir) tamamlar.
	tx, err := h.db.Begin()
	if err != nil {
		internalErr(c, err)
		return
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE auth.users SET deleting_at = COALESCE(deleting_at, now()) WHERE id = $1`, id); err != nil {
		internalErr(c, err)
		return
	}
	if _, err := tx.Exec(`UPDATE auth.sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL`, id); err != nil {
		internalErr(c, err)
		return
	}
	if err := tx.Commit(); err != nil {
		internalErr(c, err)
		return
	}

	// 2) expense verisini internal API ile sildir, sonra auth satirlarini kaldir.
	if err := h.finishAccountDeletion(c.Request.Context(), id); err != nil {
		// Hesap artik kullanilamaz (oturumlar iptal, giris engelli); silme arka planda tamamlanacak.
		log.Printf("account deletion deferred for user %d: %v", id, err)
		c.JSON(http.StatusAccepted, gin.H{"status": "deletion_pending"})
		return
	}
	// expense oturum sonucunu kisa sure onbellekler: o pencerede gecen son yazmalarin yetim veri birakmamasi icin
	// ikinci (en iyi cabayla) temizlik. Kalici cozum degil; hesap zaten silindi.
	if h.purgeRecheck > 0 && h.purger != nil {
		time.AfterFunc(h.purgeRecheck, func() {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			if err := h.purger.PurgeUser(ctx, id); err != nil {
				log.Printf("deletion recheck purge for user %d failed: %v", id, err)
			}
		})
	}
	c.Status(http.StatusNoContent)
}

// finishAccountDeletion expense verisini (internal API) ve ardindan kullanicinin auth satirlarini kalici siler.
// Idempotenttir; expense temizligi basarisiz olursa auth satirlari KORUNUR (silme yeniden denenebilsin) ve hata doner.
func (h *handler) finishAccountDeletion(ctx context.Context, id int64) error {
	var email string
	err := h.db.QueryRow(`SELECT email FROM auth.users WHERE id = $1`, id).Scan(&email)
	if errors.Is(err, sql.ErrNoRows) {
		return nil // zaten silinmis
	}
	if err != nil {
		return err
	}
	if h.purger == nil {
		return errors.New("user purger not configured")
	}
	if err := h.purger.PurgeUser(ctx, id); err != nil {
		return err
	}
	tx, err := h.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// sessions silinince refresh_tokens cascade ile gider.
	for _, q := range []struct {
		stmt string
		arg  any
	}{
		{`DELETE FROM auth.sessions WHERE user_id = $1`, id},
		{`DELETE FROM auth.users WHERE id = $1`, id},
		{`DELETE FROM auth.email_otps WHERE email = $1`, email},
	} {
		if _, err := tx.Exec(q.stmt, q.arg); err != nil {
			return err
		}
	}
	return tx.Commit()
}
