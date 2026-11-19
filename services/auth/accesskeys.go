package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"github.com/golang-jwt/jwt/v5"
)

// Access token imza/dogrulama anahtarlari (expense/accesskeys.go ile ayni sozlesme). Iki kip:
//   - HS256 (varsayilan): iki serviste ortak JWT_ACCESS_SECRET.
//   - EdDSA: bu servis JWT_ED25519_PRIVATE_KEY ile imzalar; expense yalniz genel anahtari (JWT_ED25519_PUBLIC_KEY) tutar,
//     ele gecirilse bile token uretemez. EdDSA kipinde HS256 token'lar reddedilir.
//
// Anahtar uretimi: `auth genkey` (yeni bir cift yazdirir).

// accessVerifier access token dogrulayicisi (HS256 ya da EdDSA).
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

// signingMethodAndKey config'e gore imza yontemini ve anahtarini dondurur.
func (c config) signingMethodAndKey() (jwt.SigningMethod, any) {
	if c.edPrivate != nil {
		return jwt.SigningMethodEdDSA, c.edPrivate
	}
	return jwt.SigningMethodHS256, c.accessSecret
}

// verifier bu servisin kendi uclarindaki (oturum listesi vb.) token dogrulayicisi.
func (c config) verifier() accessVerifier {
	if c.edPrivate != nil {
		return accessVerifier{ed: c.edPrivate.Public().(ed25519.PublicKey)}
	}
	return hmacVerifier(c.accessSecret)
}

// parseEdPrivateKey base64 kodlu 64 baytlik Ed25519 ozel anahtarini (ya da 32 baytlik tohumunu) okur.
func parseEdPrivateKey(b64 string) (ed25519.PrivateKey, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return nil, errors.New("JWT_ED25519_PRIVATE_KEY: gecerli base64 degil")
	}
	switch len(raw) {
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(raw), nil
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(raw), nil
	}
	return nil, errors.New("JWT_ED25519_PRIVATE_KEY: 64 baytlik ozel anahtar (ya da 32 baytlik tohum) olmali")
}

// generateEdKeyPair yeni bir Ed25519 cifti uretir (base64): private -> auth, public -> expense.
func generateEdKeyPair() (privateB64, publicB64 string, err error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(priv), base64.StdEncoding.EncodeToString(pub), nil
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
	if getenv("JWT_ED25519_PRIVATE_KEY") == "" {
		s := getenv("JWT_ACCESS_SECRET")
		if s == "" {
			s = getenv("JWT_SECRET")
		}
		if weak(s, 32) {
			problems = append(problems, "JWT_ACCESS_SECRET/JWT_SECRET en az 32 karakter ve varsayilan olmayan bir deger olmali (ya da JWT_ED25519_PRIVATE_KEY kullanin)")
		}
	}
	if r := getenv("JWT_REFRESH_SECRET"); weak(r, 32) {
		problems = append(problems, "JWT_REFRESH_SECRET acikca ve en az 32 karakter olarak verilmeli")
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
