package main

import (
	"encoding/json"
	"fmt"
	"testing"
)

// Butce ve tekrarlayan gider uc noktalari: hesap/profil izolasyonu (gercek Postgres; bkz. isolation_pg_test.go).

func (e *xenv) putBudget(uid int64, profileID int64, cat int, limit float64) (int, budgetOut, []byte) {
	e.t.Helper()
	code, b := e.as(uid, "PUT", "/budgets", map[string]any{"profile_id": profileID, "category_id": cat, "monthly_limit": limit})
	var out budgetOut
	_ = json.Unmarshal(b, &out)
	return code, out, b
}

func (e *xenv) budgets(uid int64, query string) []budgetOut {
	e.t.Helper()
	code, b := e.as(uid, "GET", "/budgets"+query, nil)
	e.want(code, 200, b, "list budgets")
	var out []budgetOut
	_ = json.Unmarshal(b, &out)
	return out
}

func TestPGBudgetsAreScopedByAccountAndProfile(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	market, cafe := e.cats["Market / Gıda"], e.cats["Restoran / Kafe"]

	aPersonal := e.profiles(alice)[0]
	aHome := e.newProfile(alice, "Ev")
	bPersonal := e.profiles(bob)[0]

	code, b1, raw := e.putBudget(alice, aPersonal.ID, market, 8000)
	e.want(code, 200, raw, "put budget")
	if b1.MonthlyLimit != 8000 || b1.ProfileID != aPersonal.ID || b1.CategoryName != "Market / Gıda" {
		t.Fatalf("budget: %+v", b1)
	}
	// Ayni profil+kategori tekrar -> guncelleme (ikinci satir olusmaz).
	code, b1b, raw := e.putBudget(alice, aPersonal.ID, market, 9000)
	e.want(code, 200, raw, "update budget")
	if b1b.ID != b1.ID || b1b.MonthlyLimit != 9000 {
		t.Fatalf("upsert must update in place: %+v vs %+v", b1b, b1)
	}
	_, _, raw = e.putBudget(alice, aHome.ID, cafe, 3000)

	// Profil izolasyonu: Kisisel'in limitleri Ev'de gorunmez.
	if got := e.budgets(alice, fmt.Sprintf("?profile_id=%d", aPersonal.ID)); len(got) != 1 || got[0].CategoryID != market {
		t.Fatalf("personal budgets: %+v", got)
	}
	if got := e.budgets(alice, fmt.Sprintf("?profile_id=%d", aHome.ID)); len(got) != 1 || got[0].CategoryID != cafe {
		t.Fatalf("home budgets: %+v", got)
	}
	if got := e.budgets(alice, ""); len(got) != 2 {
		t.Fatalf("all of alice's budgets: %+v", got)
	}

	// Hesap izolasyonu: Bob hicbirini goremez, degistiremez, silemez.
	if got := e.budgets(bob, ""); len(got) != 0 {
		t.Fatalf("bob sees alice's budgets: %+v", got)
	}
	for _, tc := range []struct {
		method, path string
		body         any
	}{
		{"GET", fmt.Sprintf("/budgets?profile_id=%d", aPersonal.ID), nil},
		{"PUT", "/budgets", map[string]any{"profile_id": aPersonal.ID, "category_id": market, "monthly_limit": 1}},
		{"DELETE", fmt.Sprintf("/budgets/%d", b1.ID), nil},
		{"GET", fmt.Sprintf("/recurring?profile_id=%d", aPersonal.ID), nil},
	} {
		code, raw := e.as(bob, tc.method, tc.path, tc.body)
		e.want(code, 404, raw, "bob "+tc.method+" "+tc.path)
	}
	// Alice'in butcesi Bob'un denemelerinden etkilenmedi.
	if got := e.budgets(alice, fmt.Sprintf("?profile_id=%d", aPersonal.ID)); got[0].MonthlyLimit != 9000 {
		t.Fatalf("alice's budget changed: %+v", got)
	}
	// Bob kendi profilinde ayni kategoriye bagimsiz limit koyabilir.
	code, _, raw = e.putBudget(bob, bPersonal.ID, market, 500)
	e.want(code, 200, raw, "bob own budget")
	if got := e.budgets(alice, fmt.Sprintf("?profile_id=%d", aPersonal.ID)); got[0].MonthlyLimit != 9000 {
		t.Fatal("bob's budget leaked into alice's")
	}

	// Dogrulama.
	for _, tc := range []struct {
		cat   int
		limit float64
	}{{market, 0}, {market, -5}, {0, 100}, {9999, 100}} {
		code, _, raw := e.putBudget(alice, aPersonal.ID, tc.cat, tc.limit)
		e.want(code, 400, raw, fmt.Sprintf("invalid budget %+v", tc))
	}

	// Profil silinince butceleri de gider (ON DELETE CASCADE).
	code, raw = e.as(alice, "DELETE", fmt.Sprintf("/profiles/%d", aHome.ID), nil)
	e.want(code, 204, raw, "delete profile")
	var n int
	if err := e.db.QueryRow(`SELECT count(*) FROM expense.budgets WHERE profile_id=$1`, aHome.ID).Scan(&n); err != nil || n != 0 {
		t.Fatalf("budgets must cascade with profile: n=%d err=%v", n, err)
	}
	// Silme: sahibi 204, ikinci kez 404.
	code, raw = e.as(alice, "DELETE", fmt.Sprintf("/budgets/%d", b1.ID), nil)
	e.want(code, 204, raw, "delete budget")
	code, raw = e.as(alice, "DELETE", fmt.Sprintf("/budgets/%d", b1.ID), nil)
	e.want(code, 404, raw, "delete budget twice")
}

func TestPGBudgetSpentUsesReceiptAmountPerCategoryAndMonth(t *testing.T) {
	e := newXEnv(t)
	const alice = int64(1)
	market, cafe := e.cats["Market / Gıda"], e.cats["Restoran / Kafe"]
	p := e.profiles(alice)[0]
	home := e.newProfile(alice, "Ev")

	_, _, raw := e.putBudget(alice, p.ID, market, 1000)
	_ = raw
	e.create(alice, e.exp("A", 500, p.ID, map[string]any{"date": "2026-05-03"}))
	e.create(alice, e.exp("B", 300, p.ID, map[string]any{"date": "2026-05-20"}))
	// Baska ay, baska kategori, baska profil: toplama girmez.
	e.create(alice, e.exp("C", 400, p.ID, map[string]any{"date": "2026-04-30"}))
	e.create(alice, e.exp("D", 250, p.ID, map[string]any{"date": "2026-05-10", "category_id": cafe}))
	e.create(alice, e.exp("E", 900, home.ID, map[string]any{"date": "2026-05-10"}))

	got := e.budgets(alice, fmt.Sprintf("?profile_id=%d&date=2026-05-15", p.ID))
	if len(got) != 1 || got[0].Spent != 800 || got[0].Status != "warning" {
		t.Fatalf("may budget: %+v", got)
	}
	got = e.budgets(alice, fmt.Sprintf("?profile_id=%d&date=2026-04-15", p.ID))
	if got[0].Spent != 400 || got[0].Status != "ok" {
		t.Fatalf("april budget: %+v", got)
	}
}

func TestPGRecurringFieldsRoundTripAndProjectionIsolation(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	fatura := e.cats["Fatura / Abonelik"]
	ap := e.profiles(alice)[0]
	aHome := e.newProfile(alice, "Ev")
	e.profiles(bob)

	rec := func(merchant string, amount float64, date string, day int, pid int64) expenseOut {
		return e.create(alice, e.exp(merchant, amount, pid, map[string]any{
			"date": date, "category_id": fatura, "recurring_day": day, "recurring_remind": false,
		}))
	}
	jan := rec("Enerjisa", 300, "2026-01-25", 25, ap.ID)
	rec("Enerjisa", 400, "2026-02-25", 25, ap.ID) // ayni seri: cift sayilmaz
	rec("Netflix", 100, "2026-02-03", 31, ap.ID)  // 31. gun
	rec("Ev kirasi", 5000, "2026-02-01", 1, aHome.ID)

	if jan.RecurringDay != 25 || jan.RecurringRemind {
		t.Fatalf("recurring fields must round-trip: %+v", jan)
	}
	plain := e.create(alice, e.exp("Migros", 50, ap.ID, nil))
	if plain.RecurringDay != 0 || !plain.RecurringRemind {
		t.Fatalf("non-recurring defaults: %+v", plain)
	}
	// Liste ve tek kayit okuma da alanlari tasir.
	var found bool
	for _, x := range e.list(alice, fmt.Sprintf("?profile_id=%d", ap.ID)) {
		if x.ID == jan.ID {
			found = x.RecurringDay == 25 && !x.RecurringRemind
		}
	}
	if !found {
		t.Fatal("list must carry recurring fields")
	}

	type recResp struct {
		MonthlyTotal float64        `json:"monthly_total"`
		Count        int            `json:"count"`
		Items        []recurringOut `json:"items"`
	}
	get := func(uid int64, q string) recResp {
		code, b := e.as(uid, "GET", "/recurring"+q, nil)
		e.want(code, 200, b, "recurring")
		var r recResp
		_ = json.Unmarshal(b, &r)
		return r
	}
	personal := get(alice, fmt.Sprintf("?profile_id=%d", ap.ID))
	if personal.Count != 2 || personal.MonthlyTotal != 500 { // Enerjisa 400 (tek sayim) + Netflix 100
		t.Fatalf("personal projection: %+v", personal)
	}
	if home := get(alice, fmt.Sprintf("?profile_id=%d", aHome.ID)); home.Count != 1 || home.MonthlyTotal != 5000 {
		t.Fatalf("home projection leaked/missing: %+v", home)
	}
	if all := get(alice, ""); all.Count != 3 || all.MonthlyTotal != 5500 {
		t.Fatalf("all profiles: %+v", all)
	}
	if bobs := get(bob, ""); bobs.Count != 0 || bobs.MonthlyTotal != 0 {
		t.Fatalf("bob sees alice's recurring: %+v", bobs)
	}

	// PUT: isaret kaldirilinca seri biter.
	body := e.exp("Enerjisa", 400, ap.ID, map[string]any{"date": "2026-02-25", "category_id": fatura, "recurring_day": 0})
	for _, x := range e.list(alice, fmt.Sprintf("?profile_id=%d", ap.ID)) {
		if x.Merchant == "Enerjisa" && x.Amount == 400 {
			code, raw := e.as(alice, "PUT", fmt.Sprintf("/expenses/%d", x.ID), body)
			e.want(code, 200, raw, "unmark recurring")
		}
	}
	if r := get(alice, fmt.Sprintf("?profile_id=%d", ap.ID)); r.Count != 1 || r.MonthlyTotal != 100 {
		t.Fatalf("series must end when latest is unmarked: %+v", r)
	}

	// Gecersiz gun.
	code, raw := e.as(alice, "POST", "/expenses", e.exp("X", 1, ap.ID, map[string]any{"recurring_day": 32}))
	e.want(code, 400, raw, "recurring_day 32")
}

func TestPGBulkCarriesRecurringFlags(t *testing.T) {
	e := newXEnv(t)
	const alice = int64(1)
	fatura := e.cats["Fatura / Abonelik"]
	p := e.profiles(alice)[0]
	item := e.exp("Internet", 350, 0, map[string]any{
		"client_uid": "off-1", "category_id": fatura, "recurring_day": 12, "recurring_remind": true,
	})
	code, raw := e.as(alice, "POST", "/expenses/bulk", map[string]any{"profile_id": p.ID, "expenses": []any{item}})
	e.want(code, 200, raw, "bulk")
	got := e.list(alice, "")
	if len(got) != 1 || got[0].RecurringDay != 12 || !got[0].RecurringRemind {
		t.Fatalf("offline-queue upload must keep recurring flags: %+v", got)
	}
}
