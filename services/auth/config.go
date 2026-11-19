package main

import (
	"crypto/ed25519"
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
	// edPrivate doluysa access token'lar EdDSA ile imzalanir (bkz. accesskeys.go); bos = HS256.
	edPrivate     ed25519.PrivateKey
	refreshSecret []byte
	otpTTL        time.Duration
	smtp          smtpConfig
	// Servisler arasi iletisim (bkz. internal.go): paylasilan gizli anahtar, expense ic API adresi, bu servisin ic portu.
	internalToken      string
	expenseInternalURL string
	internalPort       string
}

func loadConfig() (config, error) {
	if err := checkProductionSecrets(os.Getenv); err != nil {
		return config{}, err
	}
	access := os.Getenv("JWT_ACCESS_SECRET")
	if access == "" {
		access = os.Getenv("JWT_SECRET")
	}
	var edPriv ed25519.PrivateKey
	if k := os.Getenv("JWT_ED25519_PRIVATE_KEY"); k != "" {
		p, err := parseEdPrivateKey(k)
		if err != nil {
			return config{}, err
		}
		edPriv = p
	}
	if access == "" && edPriv == nil {
		return config{}, errors.New("JWT_ACCESS_SECRET (veya JWT_SECRET) ya da JWT_ED25519_PRIVATE_KEY gerekli")
	}
	refresh := os.Getenv("JWT_REFRESH_SECRET")
	if refresh == "" {
		refresh = access + "|refresh"
	}
	internalToken := os.Getenv("INTERNAL_TOKEN")
	if internalToken == "" {
		return config{}, errors.New("INTERNAL_TOKEN gerekli (auth <-> expense servisler arasi iletisim)")
	}
	expenseURL := os.Getenv("EXPENSE_INTERNAL_URL")
	if expenseURL == "" {
		expenseURL = "http://expense:9090"
	}
	internalPort := os.Getenv("INTERNAL_PORT")
	if internalPort == "" {
		internalPort = "9090"
	}
	ttl := 10
	if v, err := strconv.Atoi(os.Getenv("OTP_TTL_MINUTES")); err == nil && v > 0 {
		ttl = v
	}
	return config{
		accessSecret:       []byte(access),
		edPrivate:          edPriv,
		refreshSecret:      []byte(refresh),
		otpTTL:             time.Duration(ttl) * time.Minute,
		internalToken:      internalToken,
		expenseInternalURL: expenseURL,
		internalPort:       internalPort,
		smtp: smtpConfig{
			Host: os.Getenv("SMTP_HOST"),
			Port: os.Getenv("SMTP_PORT"),
			User: os.Getenv("SMTP_USER"),
			Pass: os.Getenv("SMTP_PASS"),
			From: os.Getenv("SMTP_FROM"),
		},
	}, nil
}
