package main

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"net/mail"
	"strings"
	"time"
	"unicode"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

type handler struct {
	db        *sql.DB
	cfg       config
	mailer    Mailer
	dummyHash []byte
	rateMax   int // 0 = rota basina varsayilan IP/dakika sinirlari; testlerde yukseltilir
}

type credentials struct {
	Email      string `json:"email"`
	Password   string `json:"password"`
	Name       string `json:"name"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
}

func fail(c *gin.Context, status int, code, msg string) {
	c.AbortWithStatusJSON(status, gin.H{"error": msg, "code": code})
}

func internalErr(c *gin.Context, err error) {
	log.Printf("internal error: %v", err)
	fail(c, http.StatusInternalServerError, "internal", "internal error")
}

func normEmail(s string) string { return strings.ToLower(strings.TrimSpace(s)) }

func validEmail(s string) bool {
	a, err := mail.ParseAddress(s)
	return err == nil && a.Address == s
}

// validatePassword: >=8 karakter, rakam ve buyuk harf (bcrypt 72 bayt ustunu kabul etmez).
func validatePassword(p string) string {
	if len(p) < 8 {
		return "password must be at least 8 characters"
	}
	if len(p) > 72 {
		return "password must be at most 72 bytes"
	}
	var digit, upper bool
	for _, r := range p {
		if unicode.IsDigit(r) {
			digit = true
		}
		if unicode.IsUpper(r) {
			upper = true
		}
	}
	if !digit || !upper {
		return "password must contain a digit and an uppercase letter"
	}
	return ""
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

// sendOTP kodu uretip gonderir; cevrilmis HTTP hatasini c'ye yazar ve false doner.
func (h *handler) sendOTP(c *gin.Context, email, purpose string) bool {
	code, err := issueOTP(h.db, h.cfg.refreshSecret, email, purpose, h.cfg.otpTTL)
	if err != nil {
		var cd otpCooldownError
		switch {
		case errors.As(err, &cd):
			c.Header("Retry-After", itoa(int(cd.retryAfter.Seconds())+1))
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{
				"error": "please wait before requesting another code", "code": "resend_cooldown",
				"retry_after": int(cd.retryAfter.Seconds()) + 1})
		case errors.Is(err, errOTPHourly):
			fail(c, http.StatusTooManyRequests, "too_many_codes", "too many codes requested, try later")
		default:
			internalErr(c, err)
		}
		return false
	}
	if err := h.mailer.SendCode(email, purpose, code, h.cfg.otpTTL); err != nil {
		log.Printf("mail send failed (purpose=%s): %v", purpose, err)
		fail(c, http.StatusBadGateway, "email_send_failed", "could not send email")
		return false
	}
	return true
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

func (h *handler) register(c *gin.Context) {
	var in credentials
	if err := c.ShouldBindJSON(&in); err != nil {
		fail(c, http.StatusBadRequest, "bad_request", "invalid request body")
		return
	}
	email := normEmail(in.Email)
	if !validEmail(email) {
		fail(c, http.StatusBadRequest, "invalid_email", "invalid email")
		return
	}
	if msg := validatePassword(in.Password); msg != "" {
		fail(c, http.StatusBadRequest, "weak_password", msg)
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(in.Password), bcrypt.DefaultCost)
	if err != nil {
		internalErr(c, err)
		return
	}
	name := clip(in.Name, 80)

	tx, err := h.db.Begin()
	if err != nil {
		internalErr(c, err)
		return
	}
	defer tx.Rollback()
	// Ayni e-postayla eszamanli kayitlar sira ile islensin.
	if _, err := tx.Exec(`SELECT pg_advisory_xact_lock(hashtext($1))`, "reg|"+email); err != nil {
		internalErr(c, err)
		return
	}
	var id int64
	var verified sql.NullTime
	err = tx.QueryRow(`SELECT id, email_verified_at FROM auth.users WHERE email=$1`, email).Scan(&id, &verified)
	switch {
	case err == nil && verified.Valid:
		fail(c, http.StatusConflict, "email_taken", "email already registered")
		return
	case err == nil:
		// Dogrulanmamis hesap: sahibi tekrar deniyor; sifre/ad guncellenir, yeni kod gider.
		_, err = tx.Exec(`UPDATE auth.users SET password_hash=$1, name=$2 WHERE id=$3`, string(hash), name, id)
	case errors.Is(err, sql.ErrNoRows):
		err = tx.QueryRow(
			`INSERT INTO auth.users (email, password_hash, name) VALUES ($1,$2,$3) RETURNING id`,
			email, string(hash), name).Scan(&id)
	}
	if err != nil {
		internalErr(c, err)
		return
	}
	if err := tx.Commit(); err != nil {
		internalErr(c, err)
		return
	}
	if !h.sendOTP(c, email, "verify") {
		return
	}
	c.JSON(http.StatusCreated, gin.H{
		"email": email, "verification_required": true,
		"resend_after_seconds": int(otpResendWindow.Seconds()),
		"expires_in_seconds":   int(h.cfg.otpTTL.Seconds()),
	})
}

type verifyInput struct {
	Email       string `json:"email"`
	Code        string `json:"code"`
	NewPassword string `json:"new_password"`
	DeviceName  string `json:"device_name"`
	Platform    string `json:"platform"`
}

func otpFail(c *gin.Context, err error) {
	switch {
	case errors.Is(err, errOTPInvalid):
		fail(c, http.StatusBadRequest, "invalid_code", "invalid code")
	case errors.Is(err, errOTPExpired):
		fail(c, http.StatusBadRequest, "code_expired", "code expired")
	case errors.Is(err, errOTPLocked):
		fail(c, http.StatusTooManyRequests, "too_many_attempts", "too many attempts")
	default:
		internalErr(c, err)
	}
}

// loginResponse yeni oturum acip token cifti ile kullanici bilgisini yazar.
func (h *handler) loginResponse(c *gin.Context, userID int64, email, name, device, platform string) {
	sid, refresh, err := h.createSession(userID, clip(device, 80), clip(platform, 40), c.ClientIP())
	if err != nil {
		internalErr(c, err)
		return
	}
	access, exp, err := h.accessFor(userID, sid)
	if err != nil {
		internalErr(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"access_token": access, "refresh_token": refresh, "expires_at": exp,
		"user": gin.H{"id": userID, "email": email, "name": name},
	})
}

func (h *handler) verifyEmail(c *gin.Context) {
	var in verifyInput
	if err := c.ShouldBindJSON(&in); err != nil {
		fail(c, http.StatusBadRequest, "bad_request", "invalid request body")
		return
	}
	email := normEmail(in.Email)
	var id int64
	var name string
	err := h.db.QueryRow(`SELECT id, name FROM auth.users WHERE email=$1`, email).Scan(&id, &name)
	if errors.Is(err, sql.ErrNoRows) {
		fail(c, http.StatusBadRequest, "invalid_code", "invalid code")
		return
	}
	if err != nil {
		internalErr(c, err)
		return
	}
	if err := checkOTP(h.db, h.cfg.refreshSecret, email, "verify", strings.TrimSpace(in.Code)); err != nil {
		otpFail(c, err)
		return
	}
	if _, err := h.db.Exec(`UPDATE auth.users SET email_verified_at = COALESCE(email_verified_at, now()) WHERE id=$1`, id); err != nil {
		internalErr(c, err)
		return
	}
	h.loginResponse(c, id, email, name, in.DeviceName, in.Platform)
}

func (h *handler) resendCode(c *gin.Context) {
	var in verifyInput
	if err := c.ShouldBindJSON(&in); err != nil {
		fail(c, http.StatusBadRequest, "bad_request", "invalid request body")
		return
	}
	email := normEmail(in.Email)
	var verified sql.NullTime
	err := h.db.QueryRow(`SELECT email_verified_at FROM auth.users WHERE email=$1`, email).Scan(&verified)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && verified.Valid) {
		// Hesap yok / zaten dogrulanmis: varligi sizdirmamak icin sessizce basarili.
		c.JSON(http.StatusAccepted, gin.H{"resend_after_seconds": int(otpResendWindow.Seconds())})
		return
	}
	if err != nil {
		internalErr(c, err)
		return
	}
	if !h.sendOTP(c, email, "verify") {
		return
	}
	c.JSON(http.StatusAccepted, gin.H{"resend_after_seconds": int(otpResendWindow.Seconds())})
}

func (h *handler) login(c *gin.Context) {
	var in credentials
	if err := c.ShouldBindJSON(&in); err != nil {
		fail(c, http.StatusBadRequest, "bad_request", "invalid request body")
		return
	}
	email := normEmail(in.Email)

	var id int64
	var hash, name string
	var verified sql.NullTime
	err := h.db.QueryRow(`SELECT id, password_hash, name, email_verified_at FROM auth.users WHERE email = $1`, email).
		Scan(&id, &hash, &name, &verified)
	if errors.Is(err, sql.ErrNoRows) {
		// Zamanlama farkindan kullanici varligi sizmasin diye sahte karsilastirma.
		_ = bcrypt.CompareHashAndPassword(h.dummyHash, []byte(in.Password))
		fail(c, http.StatusUnauthorized, "invalid_credentials", "invalid email or password")
		return
	}
	if err != nil {
		internalErr(c, err)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(in.Password)) != nil {
		fail(c, http.StatusUnauthorized, "invalid_credentials", "invalid email or password")
		return
	}
	if !verified.Valid {
		// Sifre dogru: yeni kod gonder (kotu niyetli kisi baskasinin kutusunu dolduramaz). Cooldown'daysa mevcut kod gecerli.
		code, err := issueOTP(h.db, h.cfg.refreshSecret, email, "verify", h.cfg.otpTTL)
		if err == nil {
			if merr := h.mailer.SendCode(email, "verify", code, h.cfg.otpTTL); merr != nil {
				log.Printf("mail send failed (purpose=verify): %v", merr)
			}
		}
		c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "email not verified", "code": "email_not_verified", "email": email})
		return
	}
	h.loginResponse(c, id, email, name, in.DeviceName, in.Platform)
}

type refreshInput struct {
	RefreshToken string `json:"refresh_token"`
}

func (h *handler) refresh(c *gin.Context) {
	var in refreshInput
	if err := c.ShouldBindJSON(&in); err != nil || in.RefreshToken == "" {
		fail(c, http.StatusBadRequest, "bad_request", "invalid request body")
		return
	}
	tp, err := h.rotateRefresh(in.RefreshToken)
	switch {
	case errors.Is(err, errInvalidRefresh):
		fail(c, http.StatusUnauthorized, "invalid_refresh", "invalid refresh token")
		return
	case errors.Is(err, errSessionRevoked):
		fail(c, http.StatusUnauthorized, "session_revoked", "session revoked")
		return
	case err != nil:
		internalErr(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"access_token": tp.Access, "refresh_token": tp.Refresh, "expires_at": tp.ExpiresAt})
}

// logout refresh token'in oturumunu kapatir (access token suresi dolmus olsa da calisir). Idempotent.
func (h *handler) logout(c *gin.Context) {
	var in refreshInput
	if err := c.ShouldBindJSON(&in); err != nil {
		fail(c, http.StatusBadRequest, "bad_request", "invalid request body")
		return
	}
	if in.RefreshToken != "" {
		_, err := h.db.Exec(
			`UPDATE auth.sessions SET revoked_at = now() WHERE revoked_at IS NULL AND id IN
			 (SELECT session_id FROM auth.refresh_tokens WHERE token_hash = $1)`, hashRefresh(h.cfg.refreshSecret, in.RefreshToken))
		if err != nil {
			internalErr(c, err)
			return
		}
	}
	c.Status(http.StatusNoContent)
}

func (h *handler) forgotPassword(c *gin.Context) {
	var in verifyInput
	if err := c.ShouldBindJSON(&in); err != nil {
		fail(c, http.StatusBadRequest, "bad_request", "invalid request body")
		return
	}
	email := normEmail(in.Email)
	var verified sql.NullTime
	err := h.db.QueryRow(`SELECT email_verified_at FROM auth.users WHERE email=$1`, email).Scan(&verified)
	if err == nil && verified.Valid {
		code, ierr := issueOTP(h.db, h.cfg.refreshSecret, email, "reset", h.cfg.otpTTL)
		if ierr == nil {
			if merr := h.mailer.SendCode(email, "reset", code, h.cfg.otpTTL); merr != nil {
				log.Printf("mail send failed (purpose=reset): %v", merr)
			}
		}
	} else if err != nil && !errors.Is(err, sql.ErrNoRows) {
		internalErr(c, err)
		return
	}
	// Hesap var/yok ayrimi sizdirilmaz.
	c.JSON(http.StatusAccepted, gin.H{"resend_after_seconds": int(otpResendWindow.Seconds())})
}

func (h *handler) resetPassword(c *gin.Context) {
	var in verifyInput
	if err := c.ShouldBindJSON(&in); err != nil {
		fail(c, http.StatusBadRequest, "bad_request", "invalid request body")
		return
	}
	email := normEmail(in.Email)
	if msg := validatePassword(in.NewPassword); msg != "" {
		fail(c, http.StatusBadRequest, "weak_password", msg)
		return
	}
	var id int64
	err := h.db.QueryRow(`SELECT id FROM auth.users WHERE email=$1 AND email_verified_at IS NOT NULL`, email).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		fail(c, http.StatusBadRequest, "invalid_code", "invalid code")
		return
	}
	if err != nil {
		internalErr(c, err)
		return
	}
	if err := checkOTP(h.db, h.cfg.refreshSecret, email, "reset", strings.TrimSpace(in.Code)); err != nil {
		otpFail(c, err)
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(in.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		internalErr(c, err)
		return
	}
	tx, err := h.db.Begin()
	if err != nil {
		internalErr(c, err)
		return
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE auth.users SET password_hash=$1 WHERE id=$2`, string(hash), id); err != nil {
		internalErr(c, err)
		return
	}
	// Sifre degisince tum cihazlardaki oturumlar kapanir.
	if _, err := tx.Exec(`UPDATE auth.sessions SET revoked_at = now() WHERE user_id=$1 AND revoked_at IS NULL`, id); err != nil {
		internalErr(c, err)
		return
	}
	if err := tx.Commit(); err != nil {
		internalErr(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *handler) me(c *gin.Context) {
	id := c.GetInt64("userID")
	var email, name string
	var created time.Time
	var verified sql.NullTime
	err := h.db.QueryRow(`SELECT email, name, created_at, email_verified_at FROM auth.users WHERE id = $1`, id).
		Scan(&email, &name, &created, &verified)
	if err != nil {
		fail(c, http.StatusNotFound, "not_found", "user not found")
		return
	}
	_, _ = h.db.Exec(`UPDATE auth.sessions SET last_active_at = now() WHERE id = $1::uuid`, c.GetString("sid"))
	c.JSON(http.StatusOK, gin.H{"id": id, "email": email, "name": name, "created_at": created, "email_verified": verified.Valid})
}
