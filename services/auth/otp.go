package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"time"
)

// OTP hatalari; handler bunlari HTTP kodlarina cevirir.
var (
	errOTPInvalid  = errors.New("invalid code")
	errOTPExpired  = errors.New("code expired")
	errOTPLocked   = errors.New("too many attempts")
	errOTPCooldown = errors.New("resend cooldown")
	errOTPHourly   = errors.New("too many codes requested")
)

// otpCooldownError geri sayim icin kalan sureyi tasir.
type otpCooldownError struct{ retryAfter time.Duration }

func (e otpCooldownError) Error() string { return errOTPCooldown.Error() }
func (e otpCooldownError) Unwrap() error { return errOTPCooldown }

// generateCode 000000-999999 arasi 6 haneli kriptografik rastgele kod uretir.
func generateCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// hashCode kodu e-posta + amac ile baglayip HMAC-SHA256 olarak saklar (6 hane tek basina brute-force edilebilir; bu yuzden deneme siniri var).
func hashCode(pepper []byte, email, purpose, code string) string {
	m := hmac.New(sha256.New, pepper)
	m.Write([]byte("otp|" + purpose + "|" + email + "|" + code))
	return hex.EncodeToString(m.Sum(nil))
}

// issueOTP yeni kod uretir, onceki aktif kodlari gecersiz kilar. Cooldown ve saatlik limiti uygular.
func issueOTP(db *sql.DB, pepper []byte, email, purpose string, ttl time.Duration) (string, error) {
	tx, err := db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	// Ayni e-posta icin eszamanli isteklerde sirayi garanti et.
	if _, err := tx.Exec(`SELECT pg_advisory_xact_lock(hashtext($1))`, "otp|"+email); err != nil {
		return "", err
	}
	var lastSent sql.NullTime
	if err := tx.QueryRow(
		`SELECT max(last_sent_at) FROM auth.email_otps WHERE email=$1 AND purpose=$2`, email, purpose).Scan(&lastSent); err != nil {
		return "", err
	}
	if lastSent.Valid {
		if wait := otpResendWindow - time.Since(lastSent.Time); wait > 0 {
			return "", otpCooldownError{retryAfter: wait}
		}
	}
	var lastHour int
	if err := tx.QueryRow(
		`SELECT count(*) FROM auth.email_otps WHERE email=$1 AND purpose=$2 AND created_at > now() - interval '1 hour'`,
		email, purpose).Scan(&lastHour); err != nil {
		return "", err
	}
	if lastHour >= otpMaxPerHour {
		return "", errOTPHourly
	}

	code, err := generateCode()
	if err != nil {
		return "", err
	}
	if _, err := tx.Exec(
		`UPDATE auth.email_otps SET consumed_at = now() WHERE email=$1 AND purpose=$2 AND consumed_at IS NULL`,
		email, purpose); err != nil {
		return "", err
	}
	if _, err := tx.Exec(
		`INSERT INTO auth.email_otps (email, purpose, code_hash, expires_at) VALUES ($1,$2,$3, now() + $4 * interval '1 second')`,
		email, purpose, hashCode(pepper, email, purpose, code), int64(ttl.Seconds())); err != nil {
		return "", err
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return code, nil
}

// checkOTP son aktif kodu dogrular; basarida tek kullanimlik olarak tuketir.
func checkOTP(db *sql.DB, pepper []byte, email, purpose, code string) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var id int64
	var hash string
	var attempts int
	var expired bool
	err = tx.QueryRow(
		`SELECT id, code_hash, attempts, expires_at < now() FROM auth.email_otps
		 WHERE email=$1 AND purpose=$2 AND consumed_at IS NULL
		 ORDER BY id DESC LIMIT 1 FOR UPDATE`, email, purpose).Scan(&id, &hash, &attempts, &expired)
	if errors.Is(err, sql.ErrNoRows) {
		return errOTPExpired
	}
	if err != nil {
		return err
	}
	if expired {
		return errOTPExpired
	}
	if attempts >= otpMaxAttempts {
		return errOTPLocked
	}
	if subtle.ConstantTimeCompare([]byte(hash), []byte(hashCode(pepper, email, purpose, code))) != 1 {
		if _, err := tx.Exec(`UPDATE auth.email_otps SET attempts = attempts + 1 WHERE id=$1`, id); err != nil {
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		return errOTPInvalid
	}
	if _, err := tx.Exec(`UPDATE auth.email_otps SET consumed_at = now() WHERE id=$1`, id); err != nil {
		return err
	}
	return tx.Commit()
}
