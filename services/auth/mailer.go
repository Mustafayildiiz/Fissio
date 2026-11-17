package main

import (
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"log"
	"mime"
	"net"
	"net/smtp"
	"strings"
	"time"
)

// Mailer dogrulama / sifirlama kodunu e-posta ile gonderir.
type Mailer interface {
	SendCode(to, purpose, code string, ttl time.Duration) error
}

// newMailer SMTP_HOST bos ise gelistirme icin kodu loga basan fallback doner.
func newMailer(c smtpConfig) Mailer {
	if strings.TrimSpace(c.Host) == "" {
		log.Println("SMTP_HOST bos: e-posta gonderilmeyecek, kodlar loga yazilacak (yalnizca gelistirme)")
		return logMailer{}
	}
	return &smtpMailer{cfg: c}
}

type logMailer struct{}

func (logMailer) SendCode(to, purpose, code string, ttl time.Duration) error {
	log.Printf("[DEV-OTP] email=%s purpose=%s code=%s ttl=%s", to, purpose, code, ttl)
	return nil
}

type smtpMailer struct{ cfg smtpConfig }

func mailContent(purpose, code string, ttl time.Duration) (subject, body string) {
	mins := int(ttl.Minutes())
	switch purpose {
	case "reset":
		subject = "Fissio şifre sıfırlama kodun"
		body = fmt.Sprintf("Şifreni sıfırlamak için kodun: %s\n\nKod %d dakika geçerlidir. Bu isteği sen yapmadıysan bu e-postayı yok sayabilirsin.\n\nFissio", code, mins)
	default:
		subject = "Fissio doğrulama kodun"
		body = fmt.Sprintf("E-posta adresini doğrulamak için kodun: %s\n\nKod %d dakika geçerlidir. Hesabı sen oluşturmadıysan bu e-postayı yok sayabilirsin.\n\nFissio", code, mins)
	}
	return
}

func (m *smtpMailer) SendCode(to, purpose, code string, ttl time.Duration) error {
	subject, body := mailContent(purpose, code, ttl)
	from := m.cfg.From
	if from == "" {
		from = m.cfg.User
	}
	msg := buildMessage(from, to, subject, body)
	port := m.cfg.Port
	if port == "" {
		port = "587"
	}
	addr := net.JoinHostPort(m.cfg.Host, port)
	var auth smtp.Auth
	if m.cfg.User != "" {
		auth = smtp.PlainAuth("", m.cfg.User, m.cfg.Pass, m.cfg.Host)
	}
	if port == "465" {
		return sendImplicitTLS(addr, m.cfg.Host, auth, from, to, msg)
	}
	// 587: SendMail sunucu destekliyorsa STARTTLS kullanir.
	return smtp.SendMail(addr, auth, bareAddress(from), []string{to}, msg)
}

func sendImplicitTLS(addr, host string, auth smtp.Auth, from, to string, msg []byte) error {
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 10 * time.Second}, "tcp", addr, &tls.Config{ServerName: host})
	if err != nil {
		return err
	}
	cl, err := smtp.NewClient(conn, host)
	if err != nil {
		return err
	}
	defer cl.Close()
	if auth != nil {
		if err := cl.Auth(auth); err != nil {
			return err
		}
	}
	if err := cl.Mail(bareAddress(from)); err != nil {
		return err
	}
	if err := cl.Rcpt(to); err != nil {
		return err
	}
	w, err := cl.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(msg); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return cl.Quit()
}

// bareAddress "Ad <a@b.c>" bicimindeki adresten yalniz a@b.c doner.
func bareAddress(s string) string {
	if i := strings.LastIndex(s, "<"); i >= 0 {
		if j := strings.Index(s[i:], ">"); j > 0 {
			return s[i+1 : i+j]
		}
	}
	return s
}

func buildMessage(from, to, subject, body string) []byte {
	enc := base64.StdEncoding.EncodeToString([]byte(body))
	var wrapped strings.Builder
	for len(enc) > 76 {
		wrapped.WriteString(enc[:76] + "\r\n")
		enc = enc[76:]
	}
	wrapped.WriteString(enc + "\r\n")
	h := []string{
		"From: " + from,
		"To: " + to,
		"Subject: " + mime.QEncoding.Encode("utf-8", subject),
		"MIME-Version: 1.0",
		"Content-Type: text/plain; charset=utf-8",
		"Content-Transfer-Encoding: base64",
		"Date: " + time.Now().Format(time.RFC1123Z),
	}
	return []byte(strings.Join(h, "\r\n") + "\r\n\r\n" + wrapped.String())
}
