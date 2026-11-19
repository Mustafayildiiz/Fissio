package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

// Auth ile expense'in paylastigi hata/oturum sozlesmesi (auth/contract_test.go ile AYNI beklentiler): istemci (mobil)
// yalnizca `code` alanina bakar; iki servis ayni durumda ayni kodu vermeli.
func TestErrorCodeContractWithAuth(t *testing.T) {
	gin.SetMode(gin.TestMode)
	secret := []byte("contract-secret-contract-secret-0")
	good, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, accessClaims{SID: "s1", Typ: "access", RegisteredClaims: jwt.RegisteredClaims{
		Subject: "7", ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute)),
	}}).SignedString(secret)

	call := func(alive func(string, int64) (bool, error), token string) (int, string) {
		r := gin.New()
		r.GET("/x", authMiddleware(secret, alive), func(c *gin.Context) { c.Status(http.StatusNoContent) })
		req := httptest.NewRequest(http.MethodGet, "/x", nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		var body struct {
			Code string `json:"code"`
		}
		_ = json.Unmarshal(w.Body.Bytes(), &body)
		return w.Code, body.Code
	}
	cases := []struct {
		name  string
		alive func(string, int64) (bool, error)
		token string
		code  int
		want  string
	}{
		{"token yok", nil, "", 401, "unauthorized"},
		{"bozuk token", nil, "xxx", 401, "unauthorized"},
		{"iptal edilmis oturum", func(string, int64) (bool, error) { return false, nil }, good, 401, "session_revoked"},
		{"auth erisilemez", func(string, int64) (bool, error) { return false, errAuthUnavailable }, good, 503, "auth_unavailable"},
		{"beklenmeyen hata", func(string, int64) (bool, error) { return false, errors.New("boom") }, good, 500, "internal"},
		{"gecerli", func(string, int64) (bool, error) { return true, nil }, good, 204, ""},
	}
	for _, c := range cases {
		code, got := call(c.alive, c.token)
		if code != c.code || got != c.want {
			t.Errorf("%s: %d/%q, beklenen %d/%q", c.name, code, got, c.code, c.want)
		}
	}
}

func TestServerErrorCarriesInternalCode(t *testing.T) {
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	serverError(c)
	var body map[string]string
	_ = json.Unmarshal(w.Body.Bytes(), &body)
	if w.Code != 500 || body["code"] != "internal" {
		t.Fatalf("%d %v", w.Code, body)
	}
}

func TestCorsFor(t *testing.T) {
	hdr := func(mw gin.HandlerFunc, method, origin string) (int, string) {
		r := gin.New()
		r.Use(mw)
		r.Any("/x", func(c *gin.Context) { c.Status(http.StatusOK) })
		req := httptest.NewRequest(method, "/x", nil)
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w.Code, w.Header().Get("Access-Control-Allow-Origin")
	}
	gin.SetMode(gin.TestMode)
	if _, a := hdr(corsFor("", "development"), "GET", "http://x"); a != "*" {
		t.Fatalf("gelistirme varsayilani * olmali: %q", a)
	}
	if code, a := hdr(corsFor("", "production"), "GET", "http://x"); a != "" || code != 200 {
		t.Fatalf("production varsayilani kapali olmali: %d %q", code, a)
	}
	mw := corsFor("https://app.example.com", "production")
	if _, a := hdr(mw, "GET", "https://app.example.com"); a != "https://app.example.com" {
		t.Fatalf("eslesen origin: %q", a)
	}
	if _, a := hdr(mw, "GET", "https://evil.example.com"); a != "" {
		t.Fatalf("eslesmeyen origin: %q", a)
	}
	if code, _ := hdr(mw, "OPTIONS", "https://app.example.com"); code != http.StatusNoContent {
		t.Fatalf("preflight: %d", code)
	}
}
