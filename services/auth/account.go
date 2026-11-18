package main

import (
	"database/sql"
	"errors"
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

	tx, err := h.db.Begin()
	if err != nil {
		internalErr(c, err)
		return
	}
	defer tx.Rollback()
	// expense semasi ayni veritabaninda; henuz olusmamis olabilir (to_regclass ile korunur).
	// receipt_images, expenses silinince ON DELETE CASCADE ile temizlenir.
	for _, q := range []struct{ table, stmt string }{
		{"expense.receipt_images", `DELETE FROM expense.receipt_images WHERE user_id = $1`},
		{"expense.expenses", `DELETE FROM expense.expenses WHERE user_id = $1`},
		{"expense.category_rules", `DELETE FROM expense.category_rules WHERE user_id = $1`},
		{"expense.budgets", `DELETE FROM expense.budgets WHERE user_id = $1`},
		{"expense.profiles", `DELETE FROM expense.profiles WHERE user_id = $1`},
	} {
		var exists bool
		if err := tx.QueryRow(`SELECT to_regclass($1) IS NOT NULL`, q.table).Scan(&exists); err != nil {
			internalErr(c, err)
			return
		}
		if !exists {
			continue
		}
		if _, err := tx.Exec(q.stmt, id); err != nil {
			internalErr(c, err)
			return
		}
	}
	// sessions silinince refresh_tokens cascade ile gider.
	for _, stmt := range []string{
		`DELETE FROM auth.sessions WHERE user_id = $1`,
		`DELETE FROM auth.users WHERE id = $1`,
	} {
		if _, err := tx.Exec(stmt, id); err != nil {
			internalErr(c, err)
			return
		}
	}
	if _, err := tx.Exec(`DELETE FROM auth.email_otps WHERE email = $1`, email); err != nil {
		internalErr(c, err)
		return
	}
	if err := tx.Commit(); err != nil {
		internalErr(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}
