package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// updated_at, iyimser eszamanlilik (PUT base_updated_at -> 409) ve artimli senkron (GET /expenses?since=,
// GET /expenses/ids) testleri (gercek Postgres; bkz. isolation_pg_test.go).

func decodeExpense(t *testing.T, b []byte) expenseOut {
	t.Helper()
	var out expenseOut
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("decode: %v %s", err, b)
	}
	return out
}

func mustTime(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		t.Fatalf("updated_at %q: %v", s, err)
	}
	return v
}

func TestPGUpdatedAtAndOptimisticConcurrency(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	ex := e.create(alice, e.exp("BIM", 50, 0, nil))
	if ex.UpdatedAt == "" {
		t.Fatal("created expense has no updated_at")
	}
	path := fmt.Sprintf("/expenses/%d", ex.ID)
	get := func() expenseOut {
		code, b := e.as(alice, "GET", path, nil)
		e.want(code, 200, b, "get")
		return decodeExpense(t, b)
	}

	// Fotograf ekleme updated_at'i degistirmez.
	code, b := e.upload(alice, ex.ID)
	e.want(code, 201, b, "upload")
	if g := get(); g.UpdatedAt != ex.UpdatedAt || len(g.ImageIDs) != 1 {
		t.Fatalf("image upload must not bump updated_at: %s -> %s (%v)", ex.UpdatedAt, g.UpdatedAt, g.ImageIDs)
	}

	// base yok: eskisi gibi yazilir, updated_at artar.
	code, b = e.as(alice, "PUT", path, e.exp("BIM", 60, 0, nil))
	e.want(code, 200, b, "put without base")
	v2 := decodeExpense(t, b)
	if !mustTime(t, v2.UpdatedAt).After(mustTime(t, ex.UpdatedAt)) {
		t.Fatalf("PUT must bump updated_at: %s -> %s", ex.UpdatedAt, v2.UpdatedAt)
	}

	// Bayat base: 409 + sunucudaki guncel kayit; hicbir sey yazilmaz.
	code, b = e.as(alice, "PUT", path, e.exp("BIM", 70, 0, map[string]any{"base_updated_at": ex.UpdatedAt}))
	e.want(code, 409, b, "put with stale base")
	var conflict struct {
		Error   string     `json:"error"`
		Code    string     `json:"code"`
		Current expenseOut `json:"current"`
	}
	_ = json.Unmarshal(b, &conflict)
	if conflict.Code != "conflict" || conflict.Error != "expense was modified elsewhere" || conflict.Current.ID != ex.ID ||
		conflict.Current.Amount != 60 || conflict.Current.UpdatedAt != v2.UpdatedAt || len(conflict.Current.ImageIDs) != 1 {
		t.Fatalf("conflict body: %s", b)
	}
	if g := get(); g.Amount != 60 || g.UpdatedAt != v2.UpdatedAt {
		t.Fatalf("409 must not write: %+v", g)
	}

	// Guncel base (sunucunun dondurdugu deger aynen): 200.
	code, b = e.as(alice, "PUT", path, e.exp("BIM", 70, 0, map[string]any{"base_updated_at": v2.UpdatedAt}))
	e.want(code, 200, b, "put with current base")
	v3 := decodeExpense(t, b)
	if v3.Amount != 70 || !mustTime(t, v3.UpdatedAt).After(mustTime(t, v2.UpdatedAt)) {
		t.Fatalf("put with current base: %+v", v3)
	}

	// Bicim hatasi: 400 (yazilmaz).
	code, b = e.as(alice, "PUT", path, e.exp("BIM", 80, 0, map[string]any{"base_updated_at": "dun"}))
	e.want(code, 400, b, "bad base")
	// Baska hesabin fisi + base: 404 (409 degil; icerik sizdirilmaz).
	code, b = e.as(bob, "PUT", path, e.exp("HACK", 1, 0, map[string]any{"base_updated_at": ex.UpdatedAt}))
	e.want(code, 404, b, "foreign put with base")
	if strings.Contains(string(b), "BIM") {
		t.Fatalf("foreign conflict leaks data: %s", b)
	}
	code, b = e.as(alice, "PUT", "/expenses/999999", e.exp("X", 1, 0, map[string]any{"base_updated_at": ex.UpdatedAt}))
	e.want(code, 404, b, "missing put with base")

	// Profil tasima ve tekrar isareti de updated_at'i artirir.
	home := e.newProfile(alice, "Ev")
	code, b = e.as(alice, "PUT", path, e.exp("BIM", 70, home.ID, map[string]any{"base_updated_at": v3.UpdatedAt}))
	e.want(code, 200, b, "move profile")
	v4 := decodeExpense(t, b)
	if v4.ProfileID != home.ID || !mustTime(t, v4.UpdatedAt).After(mustTime(t, v3.UpdatedAt)) {
		t.Fatalf("profile move: %+v", v4)
	}
	code, b = e.as(alice, "PUT", path, e.exp("BIM", 70, 0, map[string]any{"recurring_day": 5, "base_updated_at": v4.UpdatedAt}))
	e.want(code, 200, b, "recurring change")
	v5 := decodeExpense(t, b)
	if v5.RecurringDay != 5 || !mustTime(t, v5.UpdatedAt).After(mustTime(t, v4.UpdatedAt)) {
		t.Fatalf("recurring change: %+v", v5)
	}

	// Yaris: ayni base ile iki eszamanli PUT -> tam biri yazilir, digeri 409.
	tok := e.token(alice)
	bodies := []string{}
	for _, amt := range []float64{11, 22} {
		raw, _ := json.Marshal(e.exp("YARIS", amt, 0, map[string]any{"base_updated_at": v5.UpdatedAt}))
		bodies = append(bodies, string(raw))
	}
	codes := make([]int, 2)
	var wg sync.WaitGroup
	for i := range bodies {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			req := httptest.NewRequest("PUT", path, strings.NewReader(bodies[i]))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Authorization", "Bearer "+tok)
			w := httptest.NewRecorder()
			e.r.ServeHTTP(w, req)
			codes[i] = w.Code
		}(i)
	}
	wg.Wait()
	sort.Ints(codes)
	if codes[0] != http.StatusOK || codes[1] != http.StatusConflict {
		t.Fatalf("concurrent PUTs with the same base: %v", codes)
	}
}

func TestPGSinceAndExpenseIDs(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	a1 := e.create(alice, e.exp("A1", 10, 0, nil))
	a2 := e.create(alice, e.exp("A2", 20, 0, nil))
	home := e.newProfile(alice, "Ev")
	a3 := e.create(alice, e.exp("A3", 30, home.ID, nil))
	b1 := e.create(bob, e.exp("B1", 40, 0, nil))
	// Deterministik zamanlar (mikrosaniye hassasiyeti dahil).
	for id, ts := range map[int64]string{
		a1.ID: "2026-01-01T00:00:00.000001Z", a2.ID: "2026-01-02T00:00:00Z", a3.ID: "2026-01-03T00:00:00Z", b1.ID: "2026-01-05T00:00:00Z",
	} {
		if _, err := e.db.Exec(`UPDATE expense.expenses SET updated_at = $1 WHERE id = $2`, ts, id); err != nil {
			t.Fatal(err)
		}
	}
	names := func(list []expenseOut) string {
		var s []string
		for _, x := range list {
			s = append(s, x.Merchant)
		}
		sort.Strings(s)
		return strings.Join(s, ",")
	}
	since := func(ts string) string { return "?since=" + url.QueryEscape(ts) }

	all := e.list(alice, "")
	for _, x := range all {
		if x.Merchant == "A1" && x.UpdatedAt != "2026-01-01T00:00:00.000001Z" {
			t.Fatalf("updated_at must keep microseconds: %q", x.UpdatedAt)
		}
	}
	if got := names(e.list(alice, since("2025-12-31T00:00:00Z"))); got != "A1,A2,A3" {
		t.Fatalf("since before all: %s", got)
	}
	// Siniri dahil etmez (>), mikrosaniye hassasiyetinde.
	if got := names(e.list(alice, since("2026-01-01T00:00:00.000001Z"))); got != "A2,A3" {
		t.Fatalf("since a1: %s", got)
	}
	if got := names(e.list(alice, since("2026-01-01T00:00:00Z"))); got != "A1,A2,A3" {
		t.Fatalf("since just before a1: %s", got)
	}
	// Saat dilimi farkli yazilmis ayni an.
	if got := names(e.list(alice, since("2026-01-02T03:00:00+03:00"))); got != "A3" {
		t.Fatalf("since with offset: %s", got)
	}
	if got := names(e.list(alice, since("2026-01-03T00:00:00Z"))); got != "" {
		t.Fatalf("since latest: %s", got)
	}
	// Diger filtrelerle birlikte; baska hesabin kayitlari asla.
	if got := names(e.list(alice, since("2025-12-31T00:00:00Z")+fmt.Sprintf("&profile_id=%d", home.ID))); got != "A3" {
		t.Fatalf("since + profile: %s", got)
	}
	if got := names(e.list(alice, since("2025-12-31T00:00:00Z")+"&limit=1&offset=1")); strings.Count(got, ",") != 0 || got == "" {
		t.Fatalf("since + pagination: %s", got)
	}
	if got := names(e.list(bob, since("2025-12-31T00:00:00Z"))); got != "B1" {
		t.Fatalf("bob since: %s", got)
	}
	code, b := e.as(alice, "GET", "/expenses"+since("dun"), nil)
	e.want(code, 400, b, "bad since")
	// PUT sonrasi kayit tekrar delta'ya girer.
	code, b = e.as(alice, "PUT", fmt.Sprintf("/expenses/%d", a1.ID), e.exp("A1x", 11, 0, nil))
	e.want(code, 200, b, "put a1")
	if got := names(e.list(alice, since("2026-01-03T00:00:00Z"))); got != "A1x" {
		t.Fatalf("since after put: %s", got)
	}

	ids := func(uid int64) []int64 {
		t.Helper()
		code, b := e.as(uid, "GET", "/expenses/ids", nil)
		e.want(code, 200, b, "ids")
		var out struct {
			IDs []int64 `json:"ids"`
		}
		if err := json.Unmarshal(b, &out); err != nil || out.IDs == nil {
			t.Fatalf("ids body: %s", b)
		}
		return out.IDs
	}
	if got := fmt.Sprint(ids(alice)); got != fmt.Sprint([]int64{a1.ID, a2.ID, a3.ID}) {
		t.Fatalf("alice ids: %s", got)
	}
	if got := fmt.Sprint(ids(bob)); got != fmt.Sprint([]int64{b1.ID}) {
		t.Fatalf("bob ids: %s", got)
	}
	code, b = e.as(alice, "DELETE", fmt.Sprintf("/expenses/%d", a2.ID), nil)
	e.want(code, 204, b, "delete a2")
	if got := fmt.Sprint(ids(alice)); got != fmt.Sprint([]int64{a1.ID, a3.ID}) {
		t.Fatalf("alice ids after delete: %s", got)
	}
	// Hic fisi olmayan hesap: bos dizi (null degil).
	if got := ids(3); len(got) != 0 {
		t.Fatalf("empty account ids: %v", got)
	}
	// Kimliksiz istek reddedilir.
	code, b = e.req("", "GET", "/expenses/ids", nil)
	e.want(code, 401, b, "ids without token")
}
