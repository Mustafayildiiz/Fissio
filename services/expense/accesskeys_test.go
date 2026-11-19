package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

func status(t *testing.T, v accessVerifier, token string) int {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/x", authMiddlewareWith(v, nil), func(c *gin.Context) { c.Status(http.StatusNoContent) })
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w.Code
}

func signed(t *testing.T, m jwt.SigningMethod, key any) string {
	t.Helper()
	s, err := jwt.NewWithClaims(m, accessClaims{SID: "sid", Typ: "access", RegisteredClaims: jwt.RegisteredClaims{
		Subject: "7", ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute)),
	}}).SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// auth/accesskeys_test.go ile ayni sozlesme: EdDSA kipinde yalnizca genel anahtar vardir, HS256 token lar reddedilir.
func TestVerifierEdDSAModeAndEnvLoading(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	t.Setenv("JWT_ED25519_PUBLIC_KEY", base64.StdEncoding.EncodeToString(pub))
	t.Setenv("JWT_ACCESS_SECRET", "hs-secret-hs-secret-hs-secret-hs")
	v, err := loadAccessVerifier()
	if err != nil || v.method() != "EdDSA" {
		t.Fatalf("v=%+v err=%v", v, err)
	}
	if got := status(t, v, signed(t, jwt.SigningMethodEdDSA, priv)); got != http.StatusNoContent {
		t.Fatalf("EdDSA token kabul edilmeli: %d", got)
	}
	if got := status(t, v, signed(t, jwt.SigningMethodHS256, []byte("hs-secret-hs-secret-hs-secret-hs"))); got != http.StatusUnauthorized {
		t.Fatalf("EdDSA kipi HS256 yi reddetmeli: %d", got)
	}
	_, otherPriv, _ := ed25519.GenerateKey(nil)
	if got := status(t, v, signed(t, jwt.SigningMethodEdDSA, otherPriv)); got != http.StatusUnauthorized {
		t.Fatalf("sahte imza reddedilmeli: %d", got)
	}

	t.Setenv("JWT_ED25519_PUBLIC_KEY", "bozuk")
	if _, err := loadAccessVerifier(); err == nil {
		t.Fatal("bozuk genel anahtar reddedilmeli")
	}
	t.Setenv("JWT_ED25519_PUBLIC_KEY", "")
	v, err = loadAccessVerifier()
	if err != nil || v.method() != "HS256" {
		t.Fatalf("HS256 geri donusu: %+v %v", v, err)
	}
	if got := status(t, v, signed(t, jwt.SigningMethodHS256, []byte("hs-secret-hs-secret-hs-secret-hs"))); got != http.StatusNoContent {
		t.Fatalf("HS256 token kabul edilmeli: %d", got)
	}
}

func TestCheckProductionSecrets(t *testing.T) {
	good := map[string]string{
		"APP_ENV":           "production",
		"JWT_ACCESS_SECRET": strings.Repeat("a1b2", 10),
		"INTERNAL_TOKEN":    strings.Repeat("e5f6", 8),
		"DATABASE_URL":      "postgres://u:" + strings.Repeat("p9", 10) + "@db:5432/x",
	}
	get := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if err := checkProductionSecrets(get(good)); err != nil {
		t.Fatalf("guclu yapilandirma kabul edilmeli: %v", err)
	}
	if err := checkProductionSecrets(get(map[string]string{"JWT_SECRET": "dev_only_change_me"})); err != nil {
		t.Fatalf("gelistirme kipi serbest olmali: %v", err)
	}
	for key, bad := range map[string]string{
		"JWT_ACCESS_SECRET": "dev_only_change_me",
		"INTERNAL_TOKEN":    "dev_internal_token_change_me",
		"DATABASE_URL":      "postgres://fissio:fissio_dev_password@db:5432/x",
	} {
		m := map[string]string{}
		for k, v := range good {
			m[k] = v
		}
		m[key] = bad
		if err := checkProductionSecrets(get(m)); err == nil {
			t.Errorf("%s=%q production kipinda reddedilmeli", key, bad)
		}
	}
	// EdDSA kipinda HS256 sirri zorunlu degil.
	m := map[string]string{"APP_ENV": "production", "JWT_ED25519_PUBLIC_KEY": "x", "INTERNAL_TOKEN": good["INTERNAL_TOKEN"], "DATABASE_URL": good["DATABASE_URL"]}
	if err := checkProductionSecrets(get(m)); err != nil {
		t.Fatalf("EdDSA kipinda HS256 sirri istenmemeli: %v", err)
	}
}
