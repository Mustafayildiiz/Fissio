package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

// PG testleri yalnizca FISSIO_TEST_DATABASE_URL ("test" icermeli) tanimliysa calisir.
// DIKKAT: auth semasini DROP eder (expense testleriyle ayni veritabani); expense testleriyle PARALEL calistirma.

type captureMailer struct {
	mu      sync.Mutex
	codes   map[string]string
	sent    int
	notices []capturedNotice
}

type capturedNotice struct{ To, Subject, Body string }

func (m *captureMailer) SendNotice(to, subject, body string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.notices = append(m.notices, capturedNotice{to, subject, body})
	return nil
}

func (m *captureMailer) noticeList() []capturedNotice {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]capturedNotice(nil), m.notices...)
}

func (m *captureMailer) SendCode(to, purpose, code string, _ time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.codes[purpose+"|"+to] = code
	m.sent++
	return nil
}

func (m *captureMailer) code(purpose, email string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.codes[purpose+"|"+email]
}

func (m *captureMailer) count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.sent
}

type env struct {
	t    *testing.T
	db   *sql.DB
	h    *handler
	r    *gin.Engine
	mail *captureMailer
	purger *fakePurger
}

const testPass = "Passw0rdX"

const testInternalToken = "test-internal-token"

// fakePurger expense'in internal API'sinin taklidi: cagrilan kullanici id'lerini kaydeder, istenirse hata doner.
type fakePurger struct {
	mu   sync.Mutex
	ids  []int64
	fail error
}

func (f *fakePurger) PurgeUser(_ context.Context, id int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ids = append(f.ids, id)
	return f.fail
}

func (f *fakePurger) calls() []int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]int64(nil), f.ids...)
}

func (f *fakePurger) setErr(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fail = err
}

func newEnv(t *testing.T) *env {
	t.Helper()
	url := os.Getenv("FISSIO_TEST_DATABASE_URL")
	if url == "" || !strings.Contains(url, "test") {
		t.Skip("FISSIO_TEST_DATABASE_URL (icinde \"test\" gecen) tanimli degil")
	}
	gin.SetMode(gin.TestMode)
	db, err := sql.Open("postgres", url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	// auth artik expense semasina dokunmaz: hesap silmede expense verisi expense'in internal API'siyle (fakePurger) silinir.
	if _, err := db.Exec(`DROP SCHEMA IF EXISTS auth CASCADE`); err != nil {
		t.Fatal(err)
	}
	if err := migrate(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	cfg := config{accessSecret: []byte("access-secret"), refreshSecret: []byte("refresh-secret"), otpTTL: 10 * time.Minute, internalToken: testInternalToken}
	cm := &captureMailer{codes: map[string]string{}}
	dummy, _ := bcrypt.GenerateFromPassword([]byte("dummy"), bcrypt.MinCost)
	fp := &fakePurger{}
	h := &handler{db: db, cfg: cfg, mailer: cm, dummyHash: dummy, rateMax: 100000, purger: fp}
	return &env{t: t, db: db, h: h, r: buildRouter(h), mail: cm, purger: fp}
}

func (e *env) do(method, path string, body any, token string) (int, map[string]any) {
	e.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	e.r.ServeHTTP(w, req)
	out := map[string]any{}
	if w.Body.Len() > 0 {
		var arr []any
		if json.Unmarshal(w.Body.Bytes(), &out) != nil {
			if json.Unmarshal(w.Body.Bytes(), &arr) == nil {
				out = map[string]any{"list": arr}
			}
		}
	}
	return w.Code, out
}

func (e *env) expect(got, want int, body map[string]any, what string) {
	e.t.Helper()
	if got != want {
		e.t.Fatalf("%s: status=%d want %d body=%v", what, got, want, body)
	}
}

// signup kullaniciyi kaydedip dogrular; (access, refresh) doner.
func (e *env) signup(email, device string) (string, string) {
	e.t.Helper()
	st, b := e.do("POST", "/auth/register", map[string]any{"email": email, "password": testPass, "name": "Test"}, "")
	e.expect(st, 201, b, "register")
	code := e.mail.code("verify", email)
	if len(code) != 6 {
		e.t.Fatalf("no verification code captured for %s", email)
	}
	st, b = e.do("POST", "/auth/verify-email", map[string]any{"email": email, "code": code, "device_name": device, "platform": "android"}, "")
	e.expect(st, 200, b, "verify")
	return b["access_token"].(string), b["refresh_token"].(string)
}

func (e *env) login(email, device string) (string, string) {
	e.t.Helper()
	st, b := e.do("POST", "/auth/login", map[string]any{"email": email, "password": testPass, "device_name": device, "platform": "ios"}, "")
	e.expect(st, 200, b, "login")
	return b["access_token"].(string), b["refresh_token"].(string)
}

func TestPGRegisterVerifyLogin(t *testing.T) {
	e := newEnv(t)
	email := "ali@example.com"

	st, b := e.do("POST", "/auth/register", map[string]any{"email": email, "password": "zayif"}, "")
	e.expect(st, 400, b, "weak password")
	st, b = e.do("POST", "/auth/register", map[string]any{"email": "not-an-email", "password": testPass}, "")
	e.expect(st, 400, b, "bad email")

	st, b = e.do("POST", "/auth/register", map[string]any{"email": "ALI@Example.com ", "password": testPass, "name": "Ali"}, "")
	e.expect(st, 201, b, "register")
	if b["verification_required"] != true {
		t.Fatalf("verification_required missing: %v", b)
	}
	if _, leaked := b["code"]; leaked {
		t.Fatal("code must never be returned in the API response")
	}

	// Dogrulanmadan giris yok; yanlis sifreyle yeni kod da gonderilmez.
	before := e.mail.count()
	st, b = e.do("POST", "/auth/login", map[string]any{"email": email, "password": "Wrong1234"}, "")
	e.expect(st, 401, b, "wrong password on unverified")
	if e.mail.count() != before {
		t.Fatal("wrong password must not trigger an email (spam protection)")
	}
	st, b = e.do("POST", "/auth/login", map[string]any{"email": email, "password": testPass}, "")
	e.expect(st, 403, b, "unverified login")
	if b["code"] != "email_not_verified" {
		t.Fatalf("expected email_not_verified, got %v", b)
	}

	code := e.mail.code("verify", email)
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	st, b = e.do("POST", "/auth/verify-email", map[string]any{"email": email, "code": wrong}, "")
	e.expect(st, 400, b, "wrong code")
	if b["code"] != "invalid_code" {
		t.Fatalf("got %v", b)
	}
	st, b = e.do("POST", "/auth/verify-email", map[string]any{"email": email, "code": code, "device_name": "Pixel 8", "platform": "android"}, "")
	e.expect(st, 200, b, "verify")
	access := b["access_token"].(string)
	if b["refresh_token"] == "" {
		t.Fatal("refresh token missing")
	}

	st, b = e.do("GET", "/auth/me", nil, access)
	e.expect(st, 200, b, "me")
	if b["email"] != email || b["email_verified"] != true {
		t.Fatalf("me=%v", b)
	}
	// Kod tek kullanimlik.
	st, b = e.do("POST", "/auth/verify-email", map[string]any{"email": email, "code": code}, "")
	e.expect(st, 400, b, "code reuse")
	// Dogrulanmis e-posta tekrar kayit olamaz.
	st, b = e.do("POST", "/auth/register", map[string]any{"email": email, "password": testPass}, "")
	e.expect(st, 409, b, "duplicate")

	e.login(email, "iPhone")
	st, b = e.do("POST", "/auth/login", map[string]any{"email": email, "password": "Wrong1234"}, "")
	e.expect(st, 401, b, "wrong password")
}

func TestPGOTPExpiryAttemptsAndCooldown(t *testing.T) {
	e := newEnv(t)
	email := "otp@example.com"
	st, b := e.do("POST", "/auth/register", map[string]any{"email": email, "password": testPass}, "")
	e.expect(st, 201, b, "register")

	// Hemen tekrar gonderme -> cooldown (geri sayim icin retry_after).
	st, b = e.do("POST", "/auth/resend-code", map[string]any{"email": email}, "")
	e.expect(st, 429, b, "cooldown")
	if b["code"] != "resend_cooldown" || b["retry_after"] == nil {
		t.Fatalf("cooldown body=%v", b)
	}

	// Suresi dolmus kod.
	code := e.mail.code("verify", email)
	if _, err := e.db.Exec(`UPDATE auth.email_otps SET expires_at = now() - interval '1 second' WHERE email=$1`, email); err != nil {
		t.Fatal(err)
	}
	st, b = e.do("POST", "/auth/verify-email", map[string]any{"email": email, "code": code}, "")
	e.expect(st, 400, b, "expired")
	if b["code"] != "code_expired" {
		t.Fatalf("got %v", b)
	}

	// Cooldown bitince yeni kod gelir ve eskisi gecersiz olur.
	if _, err := e.db.Exec(`UPDATE auth.email_otps SET last_sent_at = now() - interval '2 minutes' WHERE email=$1`, email); err != nil {
		t.Fatal(err)
	}
	st, b = e.do("POST", "/auth/resend-code", map[string]any{"email": email}, "")
	e.expect(st, 202, b, "resend")
	fresh := e.mail.code("verify", email)

	// 5 hatali deneme sonrasi dogru kod bile kilitli.
	bad := "000000"
	if fresh == bad {
		bad = "111111"
	}
	for i := 0; i < 5; i++ {
		st, b = e.do("POST", "/auth/verify-email", map[string]any{"email": email, "code": bad}, "")
		e.expect(st, 400, b, "bad attempt")
	}
	st, b = e.do("POST", "/auth/verify-email", map[string]any{"email": email, "code": fresh}, "")
	e.expect(st, 429, b, "locked")
	if b["code"] != "too_many_attempts" {
		t.Fatalf("got %v", b)
	}

	// Saatlik limit: 5 kod sonrasi durur.
	if _, err := e.db.Exec(`UPDATE auth.email_otps SET last_sent_at = now() - interval '2 minutes' WHERE email=$1`, email); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		_, _ = e.do("POST", "/auth/resend-code", map[string]any{"email": email}, "")
		_, _ = e.db.Exec(`UPDATE auth.email_otps SET last_sent_at = now() - interval '2 minutes' WHERE email=$1`, email)
	}
	st, b = e.do("POST", "/auth/resend-code", map[string]any{"email": email}, "")
	e.expect(st, 429, b, "hourly limit")
	if b["code"] != "too_many_codes" {
		t.Fatalf("got %v", b)
	}

	// Var olmayan e-postada varlik sizdirilmaz.
	st, b = e.do("POST", "/auth/resend-code", map[string]any{"email": "yok@example.com"}, "")
	e.expect(st, 202, b, "unknown email")
}

func TestPGRefreshRotationAndReuseDetection(t *testing.T) {
	e := newEnv(t)
	access, refresh := e.signup("rot@example.com", "Pixel")

	st, b := e.do("POST", "/auth/refresh", map[string]any{"refresh_token": refresh}, "")
	e.expect(st, 200, b, "refresh")
	access2, refresh2 := b["access_token"].(string), b["refresh_token"].(string)
	if refresh2 == refresh || access2 == access {
		t.Fatal("tokens must rotate")
	}
	st, b = e.do("GET", "/auth/me", nil, access2)
	e.expect(st, 200, b, "new access works")

	// Grace icinde eski token: oturum dusmez, yeni cift verilir (uygulama yeni token'i kaydedemeden kapandi).
	st, b = e.do("POST", "/auth/refresh", map[string]any{"refresh_token": refresh}, "")
	e.expect(st, 200, b, "grace reuse")
	refresh3 := b["refresh_token"].(string)
	// Grace sonrasi eski token'in yeniden kullanimi = calinti: oturum iptal.
	if _, err := e.db.Exec(`UPDATE auth.refresh_tokens SET used_at = now() - interval '5 minutes'`); err != nil {
		t.Fatal(err)
	}
	st, b = e.do("POST", "/auth/refresh", map[string]any{"refresh_token": refresh2}, "")
	e.expect(st, 401, b, "reuse after grace")
	if b["code"] != "session_revoked" {
		t.Fatalf("got %v", b)
	}
	// Iptal edilen oturumun hem refresh'i hem access'i artik gecersiz.
	st, b = e.do("POST", "/auth/refresh", map[string]any{"refresh_token": refresh3}, "")
	e.expect(st, 401, b, "revoked session refresh")
	st, b = e.do("GET", "/auth/me", nil, access2)
	e.expect(st, 401, b, "revoked session access")

	st, b = e.do("POST", "/auth/refresh", map[string]any{"refresh_token": "bogus"}, "")
	e.expect(st, 401, b, "unknown token")
	if b["code"] != "invalid_refresh" {
		t.Fatalf("got %v", b)
	}
}

func TestPGRefreshStoredHashedAndExpires(t *testing.T) {
	e := newEnv(t)
	_, refresh := e.signup("hash@example.com", "Pixel")
	var n int
	if err := e.db.QueryRow(`SELECT count(*) FROM auth.refresh_tokens WHERE token_hash = $1`, refresh).Scan(&n); err != nil || n != 0 {
		t.Fatalf("raw refresh token must not be stored (n=%d err=%v)", n, err)
	}
	if _, err := e.db.Exec(`UPDATE auth.refresh_tokens SET expires_at = now() - interval '1 day'`); err != nil {
		t.Fatal(err)
	}
	st, b := e.do("POST", "/auth/refresh", map[string]any{"refresh_token": refresh}, "")
	e.expect(st, 401, b, "expired refresh")
}

func TestPGSessionsListAndRemoteLogout(t *testing.T) {
	e := newEnv(t)
	accA, refA := e.signup("dev@example.com", "Pixel 8")
	accB, _ := e.login("dev@example.com", "iPhone 15")

	st, b := e.do("GET", "/auth/sessions", nil, accA)
	e.expect(st, 200, b, "list")
	list := b["list"].([]any)
	if len(list) != 2 {
		t.Fatalf("want 2 sessions, got %d", len(list))
	}
	var otherID string
	curCount := 0
	for _, it := range list {
		s := it.(map[string]any)
		if s["current"] == true {
			curCount++
			if s["device_name"] != "Pixel 8" {
				t.Fatalf("current session device=%v", s["device_name"])
			}
		} else {
			otherID = s["id"].(string)
			if s["device_name"] != "iPhone 15" || s["platform"] != "ios" {
				t.Fatalf("other session=%v", s)
			}
		}
	}
	if curCount != 1 || otherID == "" {
		t.Fatalf("current flag wrong: %v", list)
	}

	// Uzaktan tek cihaz cikisi: B hemen dusar, A etkilenmez.
	st, b = e.do("DELETE", "/auth/sessions/"+otherID, nil, accA)
	e.expect(st, 204, b, "revoke other")
	st, b = e.do("GET", "/auth/me", nil, accB)
	e.expect(st, 401, b, "revoked device")
	st, b = e.do("GET", "/auth/me", nil, accA)
	e.expect(st, 200, b, "current device ok")
	st, b = e.do("DELETE", "/auth/sessions/"+otherID, nil, accA)
	e.expect(st, 404, b, "already revoked")

	// Baska kullanicinin oturumu silinemez.
	accC, _ := e.signup("other@example.com", "Samsung")
	st, b = e.do("GET", "/auth/sessions", nil, accC)
	cid := b["list"].([]any)[0].(map[string]any)["id"].(string)
	st, b = e.do("DELETE", "/auth/sessions/"+cid, nil, accA)
	e.expect(st, 404, b, "cross-user revoke")
	st, b = e.do("GET", "/auth/me", nil, accC)
	e.expect(st, 200, b, "other user untouched")

	// Tum cihazlardan cikis: access ve refresh tokenlari olur.
	accA2, _ := e.login("dev@example.com", "Tablet")
	st, b = e.do("POST", "/auth/logout-all", nil, accA2)
	e.expect(st, 204, b, "logout-all")
	for _, tok := range []string{accA, accA2} {
		st, b = e.do("GET", "/auth/me", nil, tok)
		e.expect(st, 401, b, "after logout-all")
	}
	st, b = e.do("POST", "/auth/refresh", map[string]any{"refresh_token": refA}, "")
	e.expect(st, 401, b, "refresh after logout-all")
	st, b = e.do("GET", "/auth/me", nil, accC)
	e.expect(st, 200, b, "other user still logged in")
}

func TestPGLogoutByRefreshToken(t *testing.T) {
	e := newEnv(t)
	acc, ref := e.signup("lo@example.com", "Pixel")
	st, b := e.do("POST", "/auth/logout", map[string]any{"refresh_token": ref}, "")
	e.expect(st, 204, b, "logout")
	st, b = e.do("GET", "/auth/me", nil, acc)
	e.expect(st, 401, b, "access after logout")
	st, b = e.do("POST", "/auth/logout", map[string]any{"refresh_token": ref}, "")
	e.expect(st, 204, b, "logout idempotent")
}

func TestPGForgotAndResetPassword(t *testing.T) {
	e := newEnv(t)
	email := "reset@example.com"
	acc, _ := e.signup(email, "Pixel")

	// Bilinmeyen e-posta: 202 ama e-posta yok.
	before := e.mail.count()
	st, b := e.do("POST", "/auth/forgot-password", map[string]any{"email": "yok@example.com"}, "")
	e.expect(st, 202, b, "unknown forgot")
	if e.mail.count() != before {
		t.Fatal("no email for unknown address")
	}

	st, b = e.do("POST", "/auth/forgot-password", map[string]any{"email": email}, "")
	e.expect(st, 202, b, "forgot")
	code := e.mail.code("reset", email)
	if len(code) != 6 {
		t.Fatal("reset code not sent")
	}
	// Dogrulama kodu ile sifirlama yapilamaz (amac ayri).
	st, b = e.do("POST", "/auth/reset-password", map[string]any{"email": email, "code": e.mail.code("verify", email), "new_password": "NewPassw0rd"}, "")
	if st == 204 {
		t.Fatal("verify code must not reset password")
	}
	st, b = e.do("POST", "/auth/reset-password", map[string]any{"email": email, "code": code, "new_password": "zayif"}, "")
	e.expect(st, 400, b, "weak new password")
	st, b = e.do("POST", "/auth/reset-password", map[string]any{"email": email, "code": code, "new_password": "NewPassw0rd"}, "")
	e.expect(st, 204, b, "reset")

	// Eski oturumlar dustu, eski sifre calismaz, yenisi calisir.
	st, b = e.do("GET", "/auth/me", nil, acc)
	e.expect(st, 401, b, "old session after reset")
	st, b = e.do("POST", "/auth/login", map[string]any{"email": email, "password": testPass}, "")
	e.expect(st, 401, b, "old password")
	st, b = e.do("POST", "/auth/login", map[string]any{"email": email, "password": "NewPassw0rd"}, "")
	e.expect(st, 200, b, "new password")
	// Kod tek kullanimlik.
	st, b = e.do("POST", "/auth/reset-password", map[string]any{"email": email, "code": code, "new_password": "Another1Pass"}, "")
	e.expect(st, 400, b, "reset code reuse")
}

func TestPGDeleteAccountWipesEverything(t *testing.T) {
	e := newEnv(t)
	acc, _ := e.signup("del@example.com", "Pixel")
	accKeep, _ := e.signup("keep@example.com", "Pixel")
	var uid, keepID int64
	if err := e.db.QueryRow(`SELECT id FROM auth.users WHERE email='del@example.com'`).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	_ = e.db.QueryRow(`SELECT id FROM auth.users WHERE email='keep@example.com'`).Scan(&keepID)

	st, b := e.do("DELETE", "/auth/account", map[string]any{"password": "Wrong1234"}, acc)
	e.expect(st, 403, b, "wrong password")
	st, b = e.do("DELETE", "/auth/account", map[string]any{}, acc)
	e.expect(st, 400, b, "missing password")
	if len(e.purger.calls()) != 0 {
		t.Fatal("expense must not be purged before the password is confirmed")
	}
	st, b = e.do("DELETE", "/auth/account", map[string]any{"password": testPass}, acc)
	e.expect(st, 204, b, "delete")

	// expense verisi expense'in internal API'siyle silinir; yalnizca silinen kullanici icin.
	if got := e.purger.calls(); len(got) != 1 || got[0] != uid {
		t.Fatalf("expense purge calls = %v, want [%d]", got, uid)
	}
	count := func(q string, id int64) int {
		var n int
		if err := e.db.QueryRow(q, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	for _, q := range []string{
		`SELECT count(*) FROM auth.users WHERE id=$1`,
		`SELECT count(*) FROM auth.sessions WHERE user_id=$1`,
		`SELECT count(*) FROM auth.refresh_tokens WHERE session_id IN (SELECT id FROM auth.sessions WHERE user_id=$1)`,
	} {
		if n := count(q, uid); n != 0 {
			t.Fatalf("%s left %d rows for deleted user", q, n)
		}
	}
	if count(`SELECT count(*) FROM auth.users WHERE id=$1`, keepID) != 1 {
		t.Fatal("other user's account was removed")
	}
	var n int
	_ = e.db.QueryRow(`SELECT count(*) FROM auth.email_otps WHERE email='del@example.com'`).Scan(&n)
	if n != 0 {
		t.Fatal("otp rows must be removed")
	}
	st, b = e.do("GET", "/auth/me", nil, acc)
	e.expect(st, 401, b, "token after delete")
	st, b = e.do("POST", "/auth/login", map[string]any{"email": "del@example.com", "password": testPass}, "")
	e.expect(st, 401, b, "login after delete")
	st, b = e.do("GET", "/auth/me", nil, accKeep)
	e.expect(st, 200, b, "other account intact")
}

// expense erisilemezken hesap silme: kullanici hemen kullanilamaz hale gelir (oturumlar iptal, giris engelli), auth satirlari
// korunur ve silme sweepDeletions ile (bekleme suresinden sonra) tamamlanir. Verinin sessizce kalmasi yok.
func TestPGDeleteAccountDeferredWhenExpenseUnavailable(t *testing.T) {
	e := newEnv(t)
	acc, _ := e.signup("pending@example.com", "Pixel")
	var uid int64
	_ = e.db.QueryRow(`SELECT id FROM auth.users WHERE email='pending@example.com'`).Scan(&uid)

	e.purger.setErr(errors.New("expense down"))
	st, b := e.do("DELETE", "/auth/account", map[string]any{"password": testPass}, acc)
	e.expect(st, 202, b, "deferred deletion")

	var deleting sql.NullTime
	if err := e.db.QueryRow(`SELECT deleting_at FROM auth.users WHERE id=$1`, uid).Scan(&deleting); err != nil || !deleting.Valid {
		t.Fatalf("user must be marked as deleting: %v %v", deleting, err)
	}
	st, b = e.do("GET", "/auth/me", nil, acc)
	e.expect(st, 401, b, "sessions revoked while deletion is pending")
	st, b = e.do("POST", "/auth/login", map[string]any{"email": "pending@example.com", "password": testPass}, "")
	e.expect(st, 401, b, "login blocked while deletion is pending")

	// Bekleme suresi dolmadan sweep dokunmaz (expense onbellek penceresi).
	e.h.sweepDeletions(context.Background())
	var n int
	_ = e.db.QueryRow(`SELECT count(*) FROM auth.users WHERE id=$1`, uid).Scan(&n)
	if n != 1 {
		t.Fatal("sweep must wait for the grace period")
	}
	// Sure doldu ama expense hala kapali: satir korunur.
	_, _ = e.db.Exec(`UPDATE auth.users SET deleting_at = now() - interval '5 minutes' WHERE id=$1`, uid)
	e.h.sweepDeletions(context.Background())
	_ = e.db.QueryRow(`SELECT count(*) FROM auth.users WHERE id=$1`, uid).Scan(&n)
	if n != 1 {
		t.Fatal("user row must be kept while expense purge keeps failing")
	}
	// expense dondu: sweep tamamlar.
	e.purger.setErr(nil)
	e.h.sweepDeletions(context.Background())
	_ = e.db.QueryRow(`SELECT count(*) FROM auth.users WHERE id=$1`, uid).Scan(&n)
	if n != 0 {
		t.Fatal("sweep must finish the deletion once expense is reachable")
	}
	if got := e.purger.calls(); got[len(got)-1] != uid {
		t.Fatalf("purge calls = %v", got)
	}
}

func TestPGInternalSessionEndpoint(t *testing.T) {
	e := newEnv(t)
	acc, _ := e.signup("sess@example.com", "Pixel")
	var uid int64
	_ = e.db.QueryRow(`SELECT id FROM auth.users WHERE email='sess@example.com'`).Scan(&uid)
	var sid string
	if err := e.db.QueryRow(`SELECT id::text FROM auth.sessions WHERE user_id=$1`, uid).Scan(&sid); err != nil {
		t.Fatal(err)
	}
	r := buildInternalRouter(e.h)
	get := func(path, token string) (int, map[string]any) {
		req := httptest.NewRequest("GET", path, nil)
		if token != "" {
			req.Header.Set(internalTokenHeader, token)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		out := map[string]any{}
		_ = json.Unmarshal(w.Body.Bytes(), &out)
		return w.Code, out
	}
	if c, _ := get("/internal/sessions/"+sid, ""); c != 401 {
		t.Fatalf("no token: %d", c)
	}
	if c, _ := get("/internal/sessions/"+sid, "wrong"); c != 401 {
		t.Fatalf("wrong token: %d", c)
	}
	c, out := get("/internal/sessions/"+sid, testInternalToken)
	if c != 200 || out["alive"] != true || int64(out["user_id"].(float64)) != uid {
		t.Fatalf("alive session: %d %v", c, out)
	}
	if c, _ := get("/internal/sessions/00000000-0000-0000-0000-000000000000", testInternalToken); c != 404 {
		t.Fatalf("unknown session: %d", c)
	}
	if c, _ := get("/internal/sessions/not-a-uuid", testInternalToken); c != 400 {
		t.Fatalf("malformed session id: %d", c)
	}
	// Cikis sonrasi oturum "alive:false".
	st, b := e.do("POST", "/auth/logout-all", nil, acc)
	e.expect(st, 204, b, "logout-all")
	c, out = get("/internal/sessions/"+sid, testInternalToken)
	if c != 200 || out["alive"] != false {
		t.Fatalf("revoked session: %d %v", c, out)
	}
	// Bos token yapilandirmasi tum istekleri reddeder.
	empty := buildInternalRouter(&handler{db: e.db, cfg: config{}})
	req := httptest.NewRequest("GET", "/internal/sessions/"+sid, nil)
	w := httptest.NewRecorder()
	empty.ServeHTTP(w, req)
	if w.Code != 401 {
		t.Fatalf("empty token config must reject: %d", w.Code)
	}
}

func TestPGMigrateBackfillsLegacyUsersOnce(t *testing.T) {
	e := newEnv(t)
	if _, err := e.db.Exec(`DROP SCHEMA auth CASCADE; CREATE SCHEMA auth;
CREATE TABLE auth.users (id BIGSERIAL PRIMARY KEY, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
INSERT INTO auth.users (email, password_hash) VALUES ('old@example.com','x');`); err != nil {
		t.Fatal(err)
	}
	if err := migrate(e.db); err != nil {
		t.Fatal(err)
	}
	var verified sql.NullTime
	_ = e.db.QueryRow(`SELECT email_verified_at FROM auth.users WHERE email='old@example.com'`).Scan(&verified)
	if !verified.Valid {
		t.Fatal("legacy users must be treated as verified")
	}
	// Yeni kayit sonrasi tekrar migrate, dogrulanmamis kullaniciyi dogrulanmis yapmamali.
	if _, err := e.db.Exec(`INSERT INTO auth.users (email, password_hash) VALUES ('new@example.com','x')`); err != nil {
		t.Fatal(err)
	}
	if err := migrate(e.db); err != nil {
		t.Fatal(err)
	}
	_ = e.db.QueryRow(`SELECT email_verified_at FROM auth.users WHERE email='new@example.com'`).Scan(&verified)
	if verified.Valid {
		t.Fatal("re-running migrate must not verify new users")
	}
}

func TestPGUnverifiedReRegisterIssuesNewCode(t *testing.T) {
	e := newEnv(t)
	email := "again@example.com"
	st, b := e.do("POST", "/auth/register", map[string]any{"email": email, "password": testPass}, "")
	e.expect(st, 201, b, "first")
	if _, err := e.db.Exec(`UPDATE auth.email_otps SET last_sent_at = now() - interval '2 minutes'`); err != nil {
		t.Fatal(err)
	}
	st, b = e.do("POST", "/auth/register", map[string]any{"email": email, "password": "Another1Pass"}, "")
	e.expect(st, 201, b, "second")
	code := e.mail.code("verify", email)
	st, b = e.do("POST", "/auth/verify-email", map[string]any{"email": email, "code": code}, "")
	e.expect(st, 200, b, "verify")
	// Sifre guncellendi.
	st, b = e.do("POST", "/auth/login", map[string]any{"email": email, "password": "Another1Pass"}, "")
	e.expect(st, 200, b, "new password works")
}

func TestPGInternalInboundFailureNotice(t *testing.T) {
	e := newEnv(t)
	e.signup("notice@example.com", "Pixel")
	var uid int64
	_ = e.db.QueryRow(`SELECT id FROM auth.users WHERE email='notice@example.com'`).Scan(&uid)
	r := buildInternalRouter(e.h)
	post := func(id int64, token string, body any) int {
		raw, _ := json.Marshal(body)
		req := httptest.NewRequest("POST", fmt.Sprintf("/internal/users/%d/inbound-failure", id), bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set(internalTokenHeader, token)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w.Code
	}
	n := map[string]any{"profile_name": "İş", "mail_subject": "Fatura\x07 Ekim", "received_at": "2026-11-23T10:00:00Z",
		"reason": "E-postada fiş tutarı bulunamadı."}
	if c := post(uid, "", n); c != 401 {
		t.Fatalf("no token: %d", c)
	}
	if c := post(uid, testInternalToken, n); c != 204 {
		t.Fatalf("notice: %d", c)
	}
	got := e.mail.noticeList()
	if len(got) != 1 || got[0].To != "notice@example.com" || !strings.Contains(got[0].Body, "Fatura Ekim") ||
		!strings.Contains(got[0].Body, "23.11.2026 13:00") || !strings.Contains(got[0].Body, "tutarı bulunamadı") ||
		!strings.Contains(got[0].Body, "Profil: İş") || strings.ContainsRune(got[0].Body, '\x07') {
		t.Fatalf("notice mail: %+v", got)
	}
	// Bilinmeyen hesap, dogrulanmamis ve silinmekte olan hesap: 404, mail yok.
	if c := post(999999, testInternalToken, n); c != 404 {
		t.Fatalf("unknown user: %d", c)
	}
	st, b := e.do("POST", "/auth/register", map[string]any{"email": "unverified@example.com", "password": testPass, "name": "U"}, "")
	e.expect(st, 201, b, "register")
	var unverified int64
	_ = e.db.QueryRow(`SELECT id FROM auth.users WHERE email='unverified@example.com'`).Scan(&unverified)
	if c := post(unverified, testInternalToken, n); c != 404 {
		t.Fatalf("unverified: %d", c)
	}
	if _, err := e.db.Exec(`UPDATE auth.users SET deleting_at = now() WHERE id = $1`, uid); err != nil {
		t.Fatal(err)
	}
	if c := post(uid, testInternalToken, n); c != 404 {
		t.Fatalf("deleting: %d", c)
	}
	if len(e.mail.noticeList()) != 1 {
		t.Fatal("reddedilen isteklerde mail gitmemeli")
	}
}
