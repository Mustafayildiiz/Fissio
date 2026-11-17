package main

import (
	"bytes"
	"encoding/base64"
	"log"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestGenerateCodeIsSixDigits(t *testing.T) {
	re := regexp.MustCompile(`^\d{6}$`)
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		c, err := generateCode()
		if err != nil || !re.MatchString(c) {
			t.Fatalf("bad code %q err=%v", c, err)
		}
		seen[c] = true
	}
	if len(seen) < 100 {
		t.Fatalf("codes look non-random: %d distinct of 200", len(seen))
	}
}

func TestHashCodeBindsEmailAndPurpose(t *testing.T) {
	p := []byte("pepper")
	a := hashCode(p, "a@b.co", "verify", "123456")
	if a != hashCode(p, "a@b.co", "verify", "123456") {
		t.Fatal("hash must be deterministic")
	}
	for _, other := range []string{
		hashCode(p, "x@b.co", "verify", "123456"),
		hashCode(p, "a@b.co", "reset", "123456"),
		hashCode(p, "a@b.co", "verify", "654321"),
		hashCode([]byte("other"), "a@b.co", "verify", "123456"),
	} {
		if other == a {
			t.Fatal("hash must differ when any input changes")
		}
	}
}

func TestValidatePassword(t *testing.T) {
	cases := map[string]bool{
		"Abcdefg1":               true,
		"abcdefg1":               false, // buyuk harf yok
		"Abcdefgh":               false, // rakam yok
		"Ab1":                    false, // kisa
		"ŞifreTest1":             true,
		strings.Repeat("A1", 37): false, // 74 bayt > 72
	}
	for p, want := range cases {
		if got := validatePassword(p) == ""; got != want {
			t.Errorf("validatePassword(%q) ok=%v want %v", p, got, want)
		}
	}
}

func TestIPLimiter(t *testing.T) {
	l := newIPLimiter(3, time.Minute)
	now := time.Now()
	l.now = func() time.Time { return now }
	for i := 0; i < 3; i++ {
		if !l.allow("1.1.1.1") {
			t.Fatalf("request %d should pass", i)
		}
	}
	if l.allow("1.1.1.1") {
		t.Fatal("4th request must be limited")
	}
	if !l.allow("2.2.2.2") {
		t.Fatal("other IP unaffected")
	}
	now = now.Add(61 * time.Second)
	if !l.allow("1.1.1.1") {
		t.Fatal("window should reset")
	}
}

func TestLogMailerFallback(t *testing.T) {
	var buf bytes.Buffer
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)

	m := newMailer(smtpConfig{}) // SMTP_HOST bos
	if _, ok := m.(logMailer); !ok {
		t.Fatalf("expected logMailer, got %T", m)
	}
	if err := m.SendCode("a@b.co", "verify", "123456", 10*time.Minute); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), "[DEV-OTP]") || !strings.Contains(buf.String(), "123456") {
		t.Fatalf("log fallback should print the code, got %q", buf.String())
	}
	if _, ok := newMailer(smtpConfig{Host: "smtp.example.com"}).(*smtpMailer); !ok {
		t.Fatal("SMTP_HOST set should yield smtpMailer")
	}
}

func TestBuildMessageEncodesTurkish(t *testing.T) {
	subj, body := mailContent("verify", "123456", 10*time.Minute)
	msg := string(buildMessage("Fissio <no-reply@fissio.app>", "a@b.co", subj, body))
	if !strings.Contains(msg, "=?utf-8?q?") {
		t.Fatalf("subject must be RFC2047 encoded: %s", msg)
	}
	parts := strings.SplitN(msg, "\r\n\r\n", 2)
	dec, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(parts[1], "\r\n", ""))
	if err != nil || !strings.Contains(string(dec), "123456") || !strings.Contains(string(dec), "doğrulamak") {
		t.Fatalf("body decode failed: %v %q", err, dec)
	}
	if bareAddress("Fissio <no-reply@fissio.app>") != "no-reply@fissio.app" {
		t.Fatal("bareAddress")
	}
}

func TestAccessTokenMiddleware(t *testing.T) {
	gin.SetMode(gin.TestMode)
	secret := []byte("s3cret")
	alive := true
	r := gin.New()
	r.GET("/x", authMiddleware(secret, func(sid string) (bool, error) { return alive, nil }), func(c *gin.Context) {
		c.JSON(200, gin.H{"uid": c.GetInt64("userID"), "sid": c.GetString("sid")})
	})
	do := func(tok string) int {
		req := httptest.NewRequest(http.MethodGet, "/x", nil)
		if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w.Code
	}
	good, _, _ := issueAccessToken(secret, 7, "sid-1", time.Minute)
	if do(good) != 200 {
		t.Fatal("valid token rejected")
	}
	if do("") != 401 {
		t.Fatal("missing token must be 401")
	}
	other, _, _ := issueAccessToken([]byte("other"), 7, "sid-1", time.Minute)
	if do(other) != 401 {
		t.Fatal("wrong secret must be 401")
	}
	expired, _, _ := issueAccessToken(secret, 7, "sid-1", -time.Minute)
	if do(expired) != 401 {
		t.Fatal("expired must be 401")
	}
	alive = false
	if do(good) != 401 {
		t.Fatal("revoked session must be 401")
	}
}

func TestRefreshHashStable(t *testing.T) {
	a := hashRefresh([]byte("k"), "tok")
	if a != hashRefresh([]byte("k"), "tok") || a == hashRefresh([]byte("k2"), "tok") || a == "tok" {
		t.Fatal("refresh hash must be deterministic, keyed and not the raw token")
	}
	t1, _ := newRefreshToken()
	t2, _ := newRefreshToken()
	if t1 == t2 || len(t1) < 40 {
		t.Fatal("refresh tokens must be long and unique")
	}
}

func TestRouteLimitersAreIndependentAndIgnoreSpoofedForwardedFor(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := buildRouter(&handler{cfg: config{accessSecret: []byte("s")}}) // db yalniz /health ve yetkili rotalarda kullanilir
	hit := func(path, xff string) int {
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader("{}"))
		req.Header.Set("Content-Type", "application/json")
		if xff != "" {
			req.Header.Set("X-Forwarded-For", xff)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w.Code
	}
	// /auth/login sinirina (30) takilir; sahte X-Forwarded-For sayaci sifirlayamaz.
	limited := false
	for i := 0; i < 40; i++ {
		if hit("/auth/login", "10.0.0."+strconv.Itoa(i)) == http.StatusTooManyRequests {
			limited = true
			break
		}
	}
	if !limited {
		t.Fatal("login must be rate limited per client IP even when X-Forwarded-For is spoofed")
	}
	// Diger rotalar kendi kotasini kullanir: login tukendi ama register hala calisir (gecersiz govde -> 400/422, 429 degil).
	if code := hit("/auth/register", ""); code == http.StatusTooManyRequests {
		t.Fatal("register must not share login's quota")
	}
}
