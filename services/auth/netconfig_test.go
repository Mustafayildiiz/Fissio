package main

import (
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestTrustedProxiesFromEnv(t *testing.T) {
	if got := trustedProxiesFromEnv(""); got != nil {
		t.Fatalf("bos = nil olmali: %v", got)
	}
	got := trustedProxiesFromEnv(" 10.0.0.0/8, 172.19.0.2 ,,")
	if !reflect.DeepEqual(got, []string{"10.0.0.0/8", "172.19.0.2"}) {
		t.Fatalf("got %v", got)
	}
}

func clientIPVia(t *testing.T, proxies []string, remote, xff string) string {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	_ = r.SetTrustedProxies(proxies)
	var ip string
	r.GET("/", func(c *gin.Context) { ip = c.ClientIP(); c.Status(http.StatusNoContent) })
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = remote
	if xff != "" {
		req.Header.Set("X-Forwarded-For", xff)
	}
	r.ServeHTTP(httptest.NewRecorder(), req)
	return ip
}

func TestClientIPOnlyTrustsConfiguredProxies(t *testing.T) {
	// Vekil tanimsiz: sahte X-Forwarded-For yok sayilir (hiz siniri asilamaz).
	if got := clientIPVia(t, nil, "203.0.113.9:5555", "1.2.3.4"); got != "203.0.113.9" {
		t.Fatalf("vekilsiz: %s", got)
	}
	// Guvenilen vekil (Caddy): gercek istemci IP'si X-Forwarded-For'dan okunur.
	if got := clientIPVia(t, []string{"172.19.0.0/16"}, "172.19.0.2:4000", "198.51.100.7"); got != "198.51.100.7" {
		t.Fatalf("guvenilen vekil: %s", got)
	}
	// Guvenilmeyen kaynaktan gelen X-Forwarded-For yok sayilir.
	if got := clientIPVia(t, []string{"172.19.0.0/16"}, "203.0.113.9:5555", "1.2.3.4"); got != "203.0.113.9" {
		t.Fatalf("guvenilmeyen kaynak: %s", got)
	}
}

func corsHeader(t *testing.T, mw gin.HandlerFunc, method, origin string) (code int, allow string) {
	t.Helper()
	gin.SetMode(gin.TestMode)
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

func TestCorsFor(t *testing.T) {
	// Gelistirme + bos: "*".
	if _, a := corsHeader(t, corsFor("", "development"), "GET", "http://x"); a != "*" {
		t.Fatalf("gelistirme varsayilani * olmali: %q", a)
	}
	// Production + bos: baslik yok (mobil CORS istemez).
	if code, a := corsHeader(t, corsFor("", "production"), "GET", "http://x"); a != "" || code != 200 {
		t.Fatalf("production varsayilani kapali olmali: %d %q", code, a)
	}
	// Liste: yalnizca eslesen origin.
	mw := corsFor("https://app.example.com, https://b.example.com", "production")
	if _, a := corsHeader(t, mw, "GET", "https://app.example.com"); a != "https://app.example.com" {
		t.Fatalf("eslesen origin: %q", a)
	}
	if _, a := corsHeader(t, mw, "GET", "https://evil.example.com"); a != "" {
		t.Fatalf("eslesmeyen origin reddedilmeli: %q", a)
	}
	if code, _ := corsHeader(t, mw, "OPTIONS", "https://app.example.com"); code != http.StatusNoContent {
		t.Fatalf("preflight: %d", code)
	}
}
