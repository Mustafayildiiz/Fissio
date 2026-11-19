package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"

	"github.com/golang-jwt/jwt/v5"
)

// accessVerifier access token'in dogrulama anahtaridir. Iki kip (auth/accesskeys.go ile ayni sozlesme):
//   - HS256 (varsayilan): iki serviste ortak JWT_ACCESS_SECRET.
//   - EdDSA: auth ozel anahtarla imzalar (JWT_ED25519_PRIVATE_KEY), expense YALNIZ genel anahtari tutar
//     (JWT_ED25519_PUBLIC_KEY): expense ele gecirilse bile token uretilemez. EdDSA kipinde HS256 token'lar reddedilir.
type accessVerifier struct {
	hmac []byte
	ed   ed25519.PublicKey
}

func hmacVerifier(secret []byte) accessVerifier { return accessVerifier{hmac: secret} }

func (v accessVerifier) method() string {
	if v.ed != nil {
		return "EdDSA"
	}
	return "HS256"
}

func (v accessVerifier) keyfunc(t *jwt.Token) (any, error) {
	if t.Method.Alg() != v.method() {
		return nil, fmt.Errorf("unexpected signing method %s", t.Method.Alg())
	}
	if v.ed != nil {
		return v.ed, nil
	}
	return v.hmac, nil
}

// loadAccessVerifier ortam degiskenlerinden dogrulayiciyi kurar: JWT_ED25519_PUBLIC_KEY (base64, 32 bayt) varsa
// EdDSA, yoksa JWT_ACCESS_SECRET / JWT_SECRET ile HS256.
func loadAccessVerifier() (accessVerifier, error) {
	if pub := strings.TrimSpace(os.Getenv("JWT_ED25519_PUBLIC_KEY")); pub != "" {
		raw, err := base64.StdEncoding.DecodeString(pub)
		if err != nil || len(raw) != ed25519.PublicKeySize {
			return accessVerifier{}, errors.New("JWT_ED25519_PUBLIC_KEY: base64 kodlu 32 baytlik Ed25519 genel anahtari olmali")
		}
		return accessVerifier{ed: ed25519.PublicKey(raw)}, nil
	}
	secret := os.Getenv("JWT_ACCESS_SECRET")
	if secret == "" {
		secret = os.Getenv("JWT_SECRET")
	}
	if secret == "" {
		return accessVerifier{}, errors.New("JWT_ED25519_PUBLIC_KEY veya JWT_ACCESS_SECRET (JWT_SECRET) gerekli")
	}
	return hmacVerifier([]byte(secret)), nil
}

// checkProductionSecrets APP_ENV=production iken zayif/varsayilan sirlari reddeder (gelistirmede hicbir sey yapmaz).
func checkProductionSecrets(getenv func(string) string) error {
	if strings.ToLower(strings.TrimSpace(getenv("APP_ENV"))) != "production" {
		return nil
	}
	weak := func(v string, minLen int) bool {
		l := strings.ToLower(v)
		return len(v) < minLen || strings.Contains(l, "change_me") || strings.Contains(l, "changeme") ||
			strings.Contains(l, "dev_")
	}
	var problems []string
	if getenv("JWT_ED25519_PUBLIC_KEY") == "" {
		s := getenv("JWT_ACCESS_SECRET")
		if s == "" {
			s = getenv("JWT_SECRET")
		}
		if weak(s, 32) {
			problems = append(problems, "JWT_ACCESS_SECRET/JWT_SECRET en az 32 karakter ve varsayilan olmayan bir deger olmali (ya da JWT_ED25519_PUBLIC_KEY kullanin)")
		}
	}
	if weak(getenv("INTERNAL_TOKEN"), 24) {
		problems = append(problems, "INTERNAL_TOKEN en az 24 karakter ve varsayilan olmayan bir deger olmali")
	}
	if u, err := url.Parse(getenv("DATABASE_URL")); err == nil && u.User != nil {
		if pw, _ := u.User.Password(); weak(pw, 16) {
			problems = append(problems, "veritabani parolasi en az 16 karakter ve varsayilan olmayan bir deger olmali")
		}
	}
	if len(problems) > 0 {
		return errors.New("APP_ENV=production icin guvensiz yapilandirma: " + strings.Join(problems, "; "))
	}
	return nil
}
