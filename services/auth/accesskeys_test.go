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

func protectedStatus(t *testing.T, v accessVerifier, token string) int {
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

func TestEdDSATokensRoundTripAndModesDoNotMix(t *testing.T) {
	privB64, pubB64, err := generateEdKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	priv, err := parseEdPrivateKey(privB64)
	if err != nil {
		t.Fatal(err)
	}
	cfg := config{edPrivate: priv, accessSecret: []byte("hs-secret-hs-secret-hs-secret-hs")}
	method, key := cfg.signingMethodAndKey()
	edTok, _, err := issueAccessTokenWith(method, key, 7, "sid-1", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	// expense tarafi: yalnizca genel anahtar
	rawPub, _ := base64.StdEncoding.DecodeString(pubB64)
	pubOnly := accessVerifier{ed: ed25519.PublicKey(rawPub)}
	if got := protectedStatus(t, pubOnly, edTok); got != http.StatusNoContent {
		t.Fatalf("EdDSA token genel anahtarla dogrulanmali: %d", got)
	}
	if got := protectedStatus(t, cfg.verifier(), edTok); got != http.StatusNoContent {
		t.Fatalf("auth kendi token ini dogrulamali: %d", got)
	}
	// EdDSA kipinde HS256 token (ayni sirla imzali) REDDEDILIR: genel anahtar bilen biri token uretemez.
	hsTok, _, _ := issueAccessToken(cfg.accessSecret, 7, "sid-1", time.Minute)
	if got := protectedStatus(t, pubOnly, hsTok); got != http.StatusUnauthorized {
		t.Fatalf("EdDSA kipi HS256 token i reddetmeli: %d", got)
	}
	// HS256 kipinde EdDSA token reddedilir.
	if got := protectedStatus(t, hmacVerifier(cfg.accessSecret), edTok); got != http.StatusUnauthorized {
		t.Fatalf("HS256 kipi EdDSA token i reddetmeli: %d", got)
	}
	// Baska anahtarla imzali EdDSA token reddedilir.
	_, otherPriv, _ := ed25519.GenerateKey(nil)
	forged, _ := jwt.NewWithClaims(jwt.SigningMethodEdDSA, accessClaims{SID: "s", Typ: "access", RegisteredClaims: jwt.RegisteredClaims{Subject: "7", ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString(otherPriv)
	if got := protectedStatus(t, pubOnly, forged); got != http.StatusUnauthorized {
		t.Fatalf("sahte imza reddedilmeli: %d", got)
	}
	// alg=none reddedilir.
	none, _ := jwt.NewWithClaims(jwt.SigningMethodNone, accessClaims{SID: "s", Typ: "access"}).SignedString(jwt.UnsafeAllowNoneSignatureType)
	if got := protectedStatus(t, pubOnly, none); got != http.StatusUnauthorized {
		t.Fatalf("alg=none reddedilmeli: %d", got)
	}
}

func TestParseEdPrivateKeyAcceptsSeedAndRejectsGarbage(t *testing.T) {
	seed := base64.StdEncoding.EncodeToString(make([]byte, ed25519.SeedSize))
	if _, err := parseEdPrivateKey(seed); err != nil {
		t.Fatalf("tohum kabul edilmeli: %v", err)
	}
	for _, bad := range []string{"", "!!!", base64.StdEncoding.EncodeToString([]byte("kisa"))} {
		if _, err := parseEdPrivateKey(bad); err == nil {
			t.Errorf("%q reddedilmeli", bad)
		}
	}
}

func TestCheckProductionSecrets(t *testing.T) {
	good := map[string]string{
		"APP_ENV":            "production",
		"JWT_ACCESS_SECRET":  strings.Repeat("a1b2", 10),
		"JWT_REFRESH_SECRET": strings.Repeat("c3d4", 10),
		"INTERNAL_TOKEN":     strings.Repeat("e5f6", 8),
		"DATABASE_URL":       "postgres://u:" + strings.Repeat("p9", 10) + "@db:5432/x",
	}
	get := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if err := checkProductionSecrets(get(good)); err != nil {
		t.Fatalf("guclu yapilandirma kabul edilmeli: %v", err)
	}
	// Gelistirmede hicbir sey denetlenmez.
	if err := checkProductionSecrets(get(map[string]string{"JWT_SECRET": "dev_only_change_me"})); err != nil {
		t.Fatalf("gelistirme kipi serbest olmali: %v", err)
	}
	for key, bad := range map[string]string{
		"JWT_ACCESS_SECRET":  "dev_only_change_me",
		"JWT_REFRESH_SECRET": "kisa",
		"INTERNAL_TOKEN":     "dev_internal_token_change_me",
		"DATABASE_URL":       "postgres://fissio:fissio_dev_password@db:5432/x",
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
}
