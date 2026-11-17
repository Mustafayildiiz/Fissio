package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

// Hesap/profil izolasyonu, idempotent toplu kayit ve oturum iptali testleri (gercek Postgres).
// YIKICIDIR: expense ve auth semalarini siler; yalnizca "test" iceren atilabilir veritabaninda calisir.
// auth testleriyle PARALEL calistirma (ayni semalari DROP eder).

var testSecret = []byte("test-access-secret")

type xenv struct {
	t        *testing.T
	db       *sql.DB
	h        *handler
	r        *gin.Engine
	sessions map[int64]string // userID -> sid
	cats     map[string]int
}

func newXEnv(t *testing.T) *xenv {
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
	// auth migrate()'i ayri modulde; yalnizca oturum kontrolunun ihtiyaci olan tablo ham DDL ile kurulur.
	for _, q := range []string{
		`DROP SCHEMA IF EXISTS expense CASCADE`,
		`DROP SCHEMA IF EXISTS auth CASCADE`,
		`CREATE SCHEMA auth`,
		`CREATE TABLE auth.sessions (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id BIGINT NOT NULL, revoked_at TIMESTAMPTZ)`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	if err := migrate(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	h := &handler{db: db}
	e := &xenv{t: t, db: db, h: h, sessions: map[int64]string{}, cats: map[string]int{}}
	e.r = buildRouter(h, testSecret, newSessionChecker(db, 0).alive)
	cats, err := h.loadCategories()
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range cats {
		e.cats[c.Name] = c.ID
	}
	return e
}

func (e *xenv) token(uid int64) string {
	e.t.Helper()
	sid, ok := e.sessions[uid]
	if !ok {
		if err := e.db.QueryRow(`INSERT INTO auth.sessions (user_id) VALUES ($1) RETURNING id::text`, uid).Scan(&sid); err != nil {
			e.t.Fatal(err)
		}
		e.sessions[uid] = sid
	}
	return signToken(uid, sid, "access", time.Minute)
}

func signToken(uid int64, sid, typ string, ttl time.Duration) string {
	claims := accessClaims{SID: sid, Typ: typ, RegisteredClaims: jwt.RegisteredClaims{
		Subject:   fmt.Sprint(uid),
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(ttl)),
	}}
	s, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(testSecret)
	return s
}

func (e *xenv) req(tok, method, path string, body any) (int, []byte) {
	e.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	w := httptest.NewRecorder()
	e.r.ServeHTTP(w, req)
	return w.Code, w.Body.Bytes()
}

// as kullanici adina istek atar.
func (e *xenv) as(uid int64, method, path string, body any) (int, []byte) {
	e.t.Helper()
	return e.req(e.token(uid), method, path, body)
}

func (e *xenv) want(code, want int, b []byte, what string) {
	e.t.Helper()
	if code != want {
		e.t.Fatalf("%s: status=%d want %d body=%s", what, code, want, b)
	}
}

func (e *xenv) profiles(uid int64) []profileOut {
	e.t.Helper()
	code, b := e.as(uid, "GET", "/profiles", nil)
	e.want(code, 200, b, "list profiles")
	var out []profileOut
	_ = json.Unmarshal(b, &out)
	return out
}

func (e *xenv) newProfile(uid int64, name string) profileOut {
	e.t.Helper()
	code, b := e.as(uid, "POST", "/profiles", map[string]any{"name": name})
	e.want(code, 201, b, "create profile")
	var p profileOut
	_ = json.Unmarshal(b, &p)
	return p
}

func (e *xenv) exp(merchant string, amount float64, profileID int64, extra map[string]any) map[string]any {
	m := map[string]any{"merchant": merchant, "amount": amount, "date": "2026-05-12", "category_id": e.cats["Market / Gıda"], "note": "", "items": []any{}}
	if profileID != 0 {
		m["profile_id"] = profileID
	}
	for k, v := range extra {
		m[k] = v
	}
	return m
}

func (e *xenv) create(uid int64, body map[string]any) expenseOut {
	e.t.Helper()
	code, b := e.as(uid, "POST", "/expenses", body)
	e.want(code, 201, b, "create expense")
	var out expenseOut
	_ = json.Unmarshal(b, &out)
	return out
}

func (e *xenv) list(uid int64, query string) []expenseOut {
	e.t.Helper()
	code, b := e.as(uid, "GET", "/expenses"+query, nil)
	e.want(code, 200, b, "list expenses")
	var out []expenseOut
	_ = json.Unmarshal(b, &out)
	return out
}

var tinyPNG = []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89")

func (e *xenv) upload(uid int64, expenseID int64) (int, []byte) {
	e.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, _ := mw.CreateFormFile("file", "r.png")
	_, _ = fw.Write(tinyPNG)
	_ = mw.Close()
	req := httptest.NewRequest("POST", fmt.Sprintf("/expenses/%d/images", expenseID), &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+e.token(uid))
	w := httptest.NewRecorder()
	e.r.ServeHTTP(w, req)
	return w.Code, w.Body.Bytes()
}

func TestPGTwoAccountsAreFullyIsolated(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)

	// Her hesap kendi varsayilan "Kisisel" profilini otomatik alir; id'ler farkli.
	ap, bp := e.profiles(alice), e.profiles(bob)
	if len(ap) != 1 || len(bp) != 1 || ap[0].Name != "Kişisel" || bp[0].Name != "Kişisel" || ap[0].ID == bp[0].ID {
		t.Fatalf("default profiles: %+v %+v", ap, bp)
	}
	aliceHome := e.newProfile(alice, "Ev")
	if got := e.profiles(bob); len(got) != 1 {
		t.Fatalf("bob must not see alice's profiles: %+v", got)
	}
	if got := e.profiles(alice); len(got) != 2 {
		t.Fatalf("alice should have 2 profiles: %+v", got)
	}

	// Alice'in fisi + gorseli.
	ex := e.create(alice, e.exp("BIM", 50, aliceHome.ID, nil))
	code, b := e.upload(alice, ex.ID)
	e.want(code, 201, b, "alice upload")
	if len(e.list(alice, "")) != 1 {
		t.Fatal("alice should see her receipt")
	}

	// Bob hicbir seyi goremez/degistiremez.
	if got := e.list(bob, ""); len(got) != 0 {
		t.Fatalf("bob sees alice's receipts: %+v", got)
	}
	for _, tc := range []struct {
		method, path string
		body         any
		what         string
	}{
		{"GET", fmt.Sprintf("/expenses/%d", ex.ID), nil, "get foreign expense"},
		{"PUT", fmt.Sprintf("/expenses/%d", ex.ID), e.exp("HACK", 1, 0, nil), "update foreign expense"},
		{"DELETE", fmt.Sprintf("/expenses/%d", ex.ID), nil, "delete foreign expense"},
		{"GET", fmt.Sprintf("/expenses/%d/images/%d", ex.ID, ex.ID), nil, "get foreign image"},
		{"GET", fmt.Sprintf("/expenses?profile_id=%d", aliceHome.ID), nil, "list foreign profile"},
		{"GET", fmt.Sprintf("/reports/summary?profile_id=%d", aliceHome.ID), nil, "summary foreign profile"},
		{"PUT", fmt.Sprintf("/profiles/%d", aliceHome.ID), map[string]any{"name": "HACK"}, "rename foreign profile"},
		{"DELETE", fmt.Sprintf("/profiles/%d", aliceHome.ID), nil, "delete foreign profile"},
		{"POST", "/expenses", e.exp("HACK", 1, aliceHome.ID, nil), "create into foreign profile"},
	} {
		code, b := e.as(bob, tc.method, tc.path, tc.body)
		e.want(code, 404, b, tc.what)
	}
	if code, b := e.upload(bob, ex.ID); code != 404 {
		t.Fatalf("bob upload into alice's receipt: %d %s", code, b)
	}
	// Bob'un kendi toplami etkilenmedi; alice'in verisi bozulmadi.
	code, b = e.as(bob, "GET", "/reports/summary?period=month&date=2026-05-12", nil)
	e.want(code, 200, b, "bob summary")
	var sum struct{ Total float64 }
	_ = json.Unmarshal(b, &sum)
	if sum.Total != 0 {
		t.Fatalf("bob summary leaks alice's data: %s", b)
	}
	got := e.list(alice, "")
	if len(got) != 1 || got[0].Merchant != "BIM" || len(got[0].ImageIDs) != 1 {
		t.Fatalf("alice's data changed: %+v", got)
	}

	// Kategori kurallari hesaba ozel.
	e.create(alice, e.exp("YILDIZ GIDA", 10, 0, map[string]any{
		"category_id": e.cats["Eğlence / Hobi"], "suggested_category_id": e.cats["Market / Gıda"]}))
	code, b = e.as(alice, "GET", "/category-rules", nil)
	var arules []categoryRuleOut
	_ = json.Unmarshal(b, &arules)
	if code != 200 || len(arules) == 0 {
		t.Fatalf("alice rules: %d %s", code, b)
	}
	code, b = e.as(bob, "GET", "/category-rules", nil)
	var brules []categoryRuleOut
	_ = json.Unmarshal(b, &brules)
	if code != 200 || len(brules) != 0 {
		t.Fatalf("bob sees alice's rules: %s", b)
	}
	code, b = e.as(bob, "DELETE", fmt.Sprintf("/category-rules/%d", arules[0].ID), nil)
	e.want(code, 404, b, "delete foreign rule")
}

func TestPGProfilesScopeReceiptsWithinAccount(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	def := e.profiles(u)[0]
	home := e.newProfile(u, "Ev")
	work := e.newProfile(u, "İş")

	a := e.create(u, e.exp("BIM", 100, def.ID, nil))
	b := e.create(u, e.exp("Migros", 200, home.ID, nil))
	_ = e.create(u, e.exp("Shell", 300, work.ID, nil))
	noProfile := e.create(u, e.exp("Varsayilan", 5, 0, nil)) // profile_id yok -> varsayilan profil
	if noProfile.ProfileID != def.ID {
		t.Fatalf("missing profile_id should use default profile: %d vs %d", noProfile.ProfileID, def.ID)
	}

	if got := e.list(u, fmt.Sprintf("?profile_id=%d", home.ID)); len(got) != 1 || got[0].ID != b.ID {
		t.Fatalf("home filter: %+v", got)
	}
	if got := e.list(u, ""); len(got) != 4 {
		t.Fatalf("all profiles: %d", len(got))
	}
	code, body := e.as(u, "GET", fmt.Sprintf("/reports/summary?date=2026-05-12&profile_id=%d", work.ID), nil)
	e.want(code, 200, body, "summary")
	var sum struct{ Total float64 }
	_ = json.Unmarshal(body, &sum)
	if sum.Total != 300 {
		t.Fatalf("work summary total=%v", sum.Total)
	}

	// Fis baska profile tasinabilir (kendi hesabinda).
	mv := e.exp("BIM", 100, work.ID, nil)
	code, body = e.as(u, "PUT", fmt.Sprintf("/expenses/%d", a.ID), mv)
	e.want(code, 200, body, "move")
	var moved expenseOut
	_ = json.Unmarshal(body, &moved)
	if moved.ProfileID != work.ID {
		t.Fatalf("not moved: %+v", moved)
	}
	// profile_id verilmeyen guncelleme profili korur.
	code, body = e.as(u, "PUT", fmt.Sprintf("/expenses/%d", a.ID), e.exp("BIM2", 100, 0, nil))
	e.want(code, 200, body, "update w/o profile")
	_ = json.Unmarshal(body, &moved)
	if moved.ProfileID != work.ID || moved.Merchant != "BIM2" {
		t.Fatalf("profile should be preserved: %+v", moved)
	}

	// Profil silinince icindeki fisler ve gorseller de gider; diger profiller etkilenmez.
	code, body = e.upload(u, b.ID)
	e.want(code, 201, body, "upload")
	code, body = e.as(u, "DELETE", fmt.Sprintf("/profiles/%d", home.ID), nil)
	e.want(code, 204, body, "delete profile")
	var n int
	_ = e.db.QueryRow(`SELECT count(*) FROM expense.expenses WHERE profile_id=$1`, home.ID).Scan(&n)
	var imgs int
	_ = e.db.QueryRow(`SELECT count(*) FROM expense.receipt_images WHERE expense_id=$1`, b.ID).Scan(&imgs)
	if n != 0 || imgs != 0 {
		t.Fatalf("profile delete left data: expenses=%d images=%d", n, imgs)
	}
	if got := e.list(u, ""); len(got) != 3 {
		t.Fatalf("other profiles affected: %d", len(got))
	}

	// Yeniden adlandirma, gecersiz ad, son profil korumasi.
	code, body = e.as(u, "PUT", fmt.Sprintf("/profiles/%d", work.ID), map[string]any{"name": "  Ofis  "})
	e.want(code, 200, body, "rename")
	code, body = e.as(u, "PUT", fmt.Sprintf("/profiles/%d", work.ID), map[string]any{"name": "   "})
	e.want(code, 400, body, "empty name")
	e.want(func() int { c, _ := e.as(u, "DELETE", fmt.Sprintf("/profiles/%d", work.ID), nil); return c }(), 204, nil, "delete work")
	code, body = e.as(u, "DELETE", fmt.Sprintf("/profiles/%d", def.ID), nil)
	e.want(code, 400, body, "last profile")
}

func TestPGDefaultProfileCreatedOnceUnderConcurrency(t *testing.T) {
	e := newXEnv(t)
	tok := e.token(77)
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			e.req(tok, "GET", "/profiles", nil)
		}()
	}
	wg.Wait()
	var n int
	_ = e.db.QueryRow(`SELECT count(*) FROM expense.profiles WHERE user_id=77`).Scan(&n)
	if n != 1 {
		t.Fatalf("concurrent GET /profiles created %d profiles", n)
	}
	// Idempotent profil olusturma (cevrimdisi kuyruk tekrari).
	for i, want := range []int{201, 200} {
		code, b := e.req(tok, "POST", "/profiles", map[string]any{"name": "Ev", "client_uid": "local-ev-1"})
		e.want(code, want, b, fmt.Sprintf("create profile #%d", i))
	}
	_ = e.db.QueryRow(`SELECT count(*) FROM expense.profiles WHERE user_id=77`).Scan(&n)
	if n != 2 {
		t.Fatalf("profiles = %d", n)
	}
}

func TestPGLegacyProfileColumnMigration(t *testing.T) {
	e := newXEnv(t)
	for _, q := range []string{
		`DROP SCHEMA expense CASCADE`,
		`CREATE SCHEMA expense`,
		`CREATE TABLE expense.categories (id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE, keywords TEXT[] NOT NULL DEFAULT '{}')`,
		`INSERT INTO expense.categories (name) VALUES ('Diğer')`,
		`CREATE TABLE expense.expenses (id BIGSERIAL PRIMARY KEY, user_id BIGINT NOT NULL, merchant TEXT NOT NULL DEFAULT '',
			amount NUMERIC(12,2) NOT NULL, spent_at DATE NOT NULL, category_id INT NOT NULL REFERENCES expense.categories(id),
			created_at TIMESTAMPTZ NOT NULL DEFAULT now(), profile_id TEXT NOT NULL DEFAULT 'default')`,
		`INSERT INTO expense.expenses (user_id, merchant, amount, spent_at, category_id) VALUES
			(1,'A',1,'2026-01-01',1),(1,'B',2,'2026-01-02',1),(2,'C',3,'2026-01-03',1)`,
	} {
		if _, err := e.db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	for i := 0; i < 2; i++ { // idempotent
		if err := migrate(e.db); err != nil {
			t.Fatalf("migrate #%d: %v", i+1, err)
		}
	}
	rows, err := e.db.Query(`SELECT e.user_id, e.client_uid, p.user_id, p.name FROM expense.expenses e JOIN expense.profiles p ON p.id = e.profile_id ORDER BY e.id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		var eu, pu int64
		var uid, name string
		_ = rows.Scan(&eu, &uid, &pu, &name)
		n++
		if eu != pu || name != "Kişisel" || !strings.HasPrefix(uid, "srv-") {
			t.Fatalf("row user=%d profile.user=%d name=%s uid=%s", eu, pu, name, uid)
		}
	}
	if n != 3 {
		t.Fatalf("rows=%d", n)
	}
	var profiles int
	_ = e.db.QueryRow(`SELECT count(*) FROM expense.profiles`).Scan(&profiles)
	if profiles != 2 {
		t.Fatalf("one default profile per user expected, got %d", profiles)
	}
	var legacy int
	_ = e.db.QueryRow(`SELECT count(*) FROM information_schema.columns WHERE table_schema='expense' AND column_name='profile_id_legacy'`).Scan(&legacy)
	if legacy != 1 {
		t.Fatal("old text column should be kept as profile_id_legacy")
	}
}

func TestPGBulkImportIsIdempotentAndExportRoundTrips(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	home := e.newProfile(u, "Ev")
	good := func(uid string) map[string]any {
		return e.exp("BIM "+uid, 25.5, 0, map[string]any{"client_uid": uid,
			"items": []any{map[string]any{"name": "SUT", "amount": 10.5, "category_id": e.cats["Market / Gıda"]}}})
	}
	bad := e.exp("BAD", -1, 0, map[string]any{"client_uid": "bad-1"})
	unknownCat := e.exp("X", 5, 0, map[string]any{"client_uid": "badcat-1", "category_id": 99999})
	noUID := e.exp("NOUID", 5, 0, nil)
	foreign := e.exp("F", 5, 424242, map[string]any{"client_uid": "foreign-1"})
	payload := map[string]any{"profile_id": home.ID, "expenses": []any{good("a-1"), good("a-2"), bad, unknownCat, noUID, foreign}}

	type result struct {
		Created, Skipped, Failed int
		Results                  []bulkResult
	}
	run := func() result {
		code, b := e.as(u, "POST", "/expenses/bulk", payload)
		e.want(code, 200, b, "bulk")
		var r result
		_ = json.Unmarshal(b, &r)
		return r
	}
	first := run()
	if first.Created != 2 || first.Skipped != 0 || first.Failed != 4 {
		t.Fatalf("first run: %+v", first)
	}
	for _, i := range []int{2, 3, 4, 5} {
		if first.Results[i].Status != "error" || first.Results[i].Error == "" {
			t.Fatalf("item %d should error: %+v", i, first.Results[i])
		}
	}
	second := run() // ayni dosya tekrar yuklenir: yeni kayit olusmaz
	if second.Created != 0 || second.Skipped != 2 {
		t.Fatalf("second run must not create duplicates: %+v", second)
	}
	if second.Results[0].ID != first.Results[0].ID {
		t.Fatal("skipped result should point at the existing receipt")
	}
	if got := e.list(u, fmt.Sprintf("?profile_id=%d", home.ID)); len(got) != 2 {
		t.Fatalf("receipts after double import = %d", len(got))
	}

	// Ayni client_uid POST /expenses ile de mukerrer olusturmaz (200 + mevcut kayit).
	code, b := e.as(u, "POST", "/expenses", good("a-1"))
	e.want(code, 200, b, "idempotent create")
	var again expenseOut
	_ = json.Unmarshal(b, &again)
	if again.ID != first.Results[0].ID {
		t.Fatalf("idempotent create returned a different receipt")
	}

	// Disa aktar (liste) -> ayni fisleri geri yukle: hepsi atlanir (sunucu uretimi 'srv-' uid'leri dahil).
	plain := e.create(u, e.exp("Elle", 9, 0, nil))
	exported := e.list(u, "")
	var again2 []any
	for _, x := range exported {
		again2 = append(again2, map[string]any{
			"client_uid": x.ClientUID, "merchant": x.Merchant, "amount": x.Amount, "date": x.Date,
			"category_id": x.CategoryID, "note": x.Note, "items": x.Items, "profile_id": x.ProfileID})
	}
	code, b = e.as(u, "POST", "/expenses/bulk", map[string]any{"expenses": again2})
	e.want(code, 200, b, "re-import export")
	var rr result
	_ = json.Unmarshal(b, &rr)
	if rr.Created != 0 || rr.Skipped != len(exported) || rr.Failed != 0 {
		t.Fatalf("re-import: %+v (plain uid=%s)", rr, plain.ClientUID)
	}

	// client_uid hesap basina tekildir: baska hesap ayni uid'i kullanabilir ve verilerin karismaz.
	code, b = e.as(2, "POST", "/expenses/bulk", map[string]any{"expenses": []any{good("a-1")}})
	e.want(code, 200, b, "other user same uid")
	var other result
	_ = json.Unmarshal(b, &other)
	if other.Created != 1 {
		t.Fatalf("same client_uid in another account must create its own receipt: %+v", other)
	}
	if got := e.list(u, ""); len(got) != len(exported) {
		t.Fatalf("account 1 changed by account 2's import: %d vs %d", len(got), len(exported))
	}

	// Sinirlar.
	code, b = e.as(u, "POST", "/expenses/bulk", map[string]any{"expenses": []any{}})
	e.want(code, 400, b, "empty bulk")
	many := make([]any, maxBulkExpenses+1)
	for i := range many {
		many[i] = good(fmt.Sprintf("m-%d", i))
	}
	code, b = e.as(u, "POST", "/expenses/bulk", map[string]any{"expenses": many})
	e.want(code, 400, b, "too many")
}

func TestPGRevokedAndMalformedSessions(t *testing.T) {
	e := newXEnv(t)
	tok := e.token(1)
	code, b := e.req(tok, "GET", "/profiles", nil)
	e.want(code, 200, b, "valid session")

	if _, err := e.db.Exec(`UPDATE auth.sessions SET revoked_at = now() WHERE id = $1::uuid`, e.sessions[1]); err != nil {
		t.Fatal(err)
	}
	code, b = e.req(tok, "GET", "/profiles", nil)
	e.want(code, 401, b, "revoked session")
	if !strings.Contains(string(b), "session_revoked") {
		t.Fatalf("body=%s", b)
	}
	// Oturumu olmayan (silinmis hesap) token.
	code, b = e.req(signToken(5, "00000000-0000-0000-0000-000000000000", "access", time.Minute), "GET", "/profiles", nil)
	e.want(code, 401, b, "unknown session")
	// Eski bicim (sid yok) / yanlis tip / suresi dolmus.
	for what, tok := range map[string]string{
		"no sid":     signToken(1, "", "access", time.Minute),
		"wrong type": signToken(1, e.sessions[1], "refresh", time.Minute),
		"expired":    signToken(1, e.sessions[1], "access", -time.Minute),
	} {
		code, b = e.req(tok, "GET", "/profiles", nil)
		e.want(code, 401, b, what)
	}
	// auth semasi henuz yokken 500 degil 503.
	if _, err := e.db.Exec(`DROP SCHEMA auth CASCADE`); err != nil {
		t.Fatal(err)
	}
	code, b = e.req(signToken(1, "00000000-0000-0000-0000-000000000001", "access", time.Minute), "GET", "/profiles", nil)
	e.want(code, 503, b, "auth schema missing")
}

func TestPGSessionCheckerCachesBriefly(t *testing.T) {
	e := newXEnv(t)
	sid := ""
	_ = e.db.QueryRow(`INSERT INTO auth.sessions (user_id) VALUES (1) RETURNING id::text`).Scan(&sid)
	chk := newSessionChecker(e.db, time.Hour)
	if ok, err := chk.alive(sid); !ok || err != nil {
		t.Fatalf("alive: %v %v", ok, err)
	}
	_, _ = e.db.Exec(`UPDATE auth.sessions SET revoked_at = now()`)
	if ok, _ := chk.alive(sid); !ok {
		t.Fatal("result should be served from cache within ttl")
	}
	if ok, _ := newSessionChecker(e.db, 0).alive(sid); ok {
		t.Fatal("uncached check must see the revocation")
	}
	_ = http.StatusOK
}
