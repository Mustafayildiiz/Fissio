package main

import (
	"errors"
	"os"
	"strconv"
	"time"
)

// Oturum ve OTP sureleri (varsayilanlar).
const (
	accessTTL       = 15 * time.Minute
	refreshTTL      = 30 * 24 * time.Hour
	refreshGrace    = 45 * time.Second // rotasyon sonrasi eski token icin tolerans (uygulama yeni token'i kaydedemeden kapanirsa)
	otpMaxAttempts  = 5
	otpResendWindow = 60 * time.Second
	otpMaxPerHour   = 5
)

type smtpConfig struct {
	Host, Port, User, Pass, From string
}

type config struct {
	accessSecret  []byte
	refreshSecret []byte
	otpTTL        time.Duration
	smtp          smtpConfig
}

func loadConfig() (config, error) {
	access := os.Getenv("JWT_ACCESS_SECRET")
	if access == "" {
		access = os.Getenv("JWT_SECRET")
	}
	if access == "" {
		return config{}, errors.New("JWT_ACCESS_SECRET (veya JWT_SECRET) gerekli")
	}
	refresh := os.Getenv("JWT_REFRESH_SECRET")
	if refresh == "" {
		refresh = access + "|refresh"
	}
	ttl := 10
	if v, err := strconv.Atoi(os.Getenv("OTP_TTL_MINUTES")); err == nil && v > 0 {
		ttl = v
	}
	return config{
		accessSecret:  []byte(access),
		refreshSecret: []byte(refresh),
		otpTTL:        time.Duration(ttl) * time.Minute,
		smtp: smtpConfig{
			Host: os.Getenv("SMTP_HOST"),
			Port: os.Getenv("SMTP_PORT"),
			User: os.Getenv("SMTP_USER"),
			Pass: os.Getenv("SMTP_PASS"),
			From: os.Getenv("SMTP_FROM"),
		},
	}, nil
}
