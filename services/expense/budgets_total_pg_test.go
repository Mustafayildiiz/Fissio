package main

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

// Toplam aylik butce (category_id NULL) ve degisken tutarli tekrarlayan giderler (gercek Postgres).

func (e *xenv) putTotalBudget(uid, profileID int64, limit float64) (int, budgetOut, []byte) {
	e.t.Helper()
	// category_id hic gonderilmez: profilin toplam butcesi.
	code, b := e.as(uid, "PUT", "/budgets", map[string]any{"profile_id": profileID, "monthly_limit": limit})
	var out budgetOut
	_ = json.Unmarshal(b, &out)
	return code, out, b
}

func TestPGTotalBudgetIsPerProfileAndCountsEveryCategory(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	market, cafe := e.cats["Market / Gıda"], e.cats["Restoran / Kafe"]
	p := e.profiles(alice)[0]
	home := e.newProfile(alice, "Ev")
	e.profiles(bob)

	code, tb, raw := e.putTotalBudget(alice, p.ID, 20000)
	e.want(code, 200, raw, "put total budget")
	if tb.CategoryID != nil || tb.MonthlyLimit != 20000 || tb.CategoryName != "Toplam bütçe" {
		t.Fatalf("total budget: %+v (%s)", tb, raw)
	}
	// Ayni profil tekrar -> yerinde guncelleme (kismi tekil indeks; ikinci toplam satir olusmaz).
	code, tb2, raw := e.putTotalBudget(alice, p.ID, 25000)
	e.want(code, 200, raw, "update total budget")
	if tb2.ID != tb.ID || tb2.MonthlyLimit != 25000 {
		t.Fatalf("total upsert must update in place: %+v vs %+v", tb2, tb)
	}
	// Kategori limitiyle yan yana yasar (ayri satir).
	code, cb, raw := e.putBudget(alice, p.ID, market, 8000)
	e.want(code, 200, raw, "category budget next to total")
	if cb.ID == tb.ID || cb.CategoryID == nil {
		t.Fatalf("category budget: %+v", cb)
	}
	// Baska profil kendi toplam limitini ayri tutar.
	_, htb, _ := e.putTotalBudget(alice, home.ID, 5000)
	if htb.ID == tb.ID {
		t.Fatal("each profile has its own total budget")
	}

	// Harcama: TUM kategoriler, yalnizca bu ay ve bu profil.
	e.create(alice, e.exp("A", 800, p.ID, map[string]any{"date": "2026-05-03"}))
	e.create(alice, e.exp("B", 1200, p.ID, map[string]any{"date": "2026-05-20", "category_id": cafe}))
	e.create(alice, e.exp("C", 9999, p.ID, map[string]any{"date": "2026-04-30"}))       // baska ay
	e.create(alice, e.exp("D", 7777, home.ID, map[string]any{"date": "2026-05-10"})) // baska profil
	got := e.budgets(alice, fmt.Sprintf("?profile_id=%d&date=2026-05-15", p.ID))
	if len(got) != 2 {
		t.Fatalf("budgets: %+v", got)
	}
	// Toplam limit listede ILK sirada.
	if got[0].CategoryID != nil || got[0].Spent != 2000 || got[0].Status != "ok" {
		t.Fatalf("total row: %+v", got[0])
	}
	if got[1].CategoryID == nil || got[1].Spent != 800 {
		t.Fatalf("category row: %+v", got[1])
	}
	// Esikler toplam limitte de gecerli: 20000 limit -> 16000 harcamada %80.
	code, _, raw = e.putTotalBudget(alice, p.ID, 2500)
	e.want(code, 200, raw, "lower total")
	got = e.budgets(alice, fmt.Sprintf("?profile_id=%d&date=2026-05-15", p.ID))
	if got[0].Status != "warning" { // 2000 / 2500 = %80
		t.Fatalf("80%% of the total budget must warn: %+v", got[0])
	}

	// Izolasyon: Bob toplam limiti goremez, degistiremez, silemez.
	if b := e.budgets(bob, ""); len(b) != 0 {
		t.Fatalf("bob sees alice's total budget: %+v", b)
	}
	code, raw = e.as(bob, "PUT", "/budgets", map[string]any{"profile_id": p.ID, "monthly_limit": 1})
	e.want(code, 404, raw, "bob put alice's total")
	code, raw = e.as(bob, "DELETE", fmt.Sprintf("/budgets/%d", tb.ID), nil)
	e.want(code, 404, raw, "bob delete alice's total")

	// Gecersiz: negatif/sifir limit; acik sifir category_id artik toplam sayilmaz, reddedilir.
	for _, limit := range []float64{0, -1} {
		code, _, raw := e.putTotalBudget(alice, p.ID, limit)
		e.want(code, 400, raw, fmt.Sprintf("invalid total limit %v", limit))
	}
	code, raw = e.as(alice, "PUT", "/budgets", map[string]any{"profile_id": p.ID, "category_id": 0, "monthly_limit": 10})
	e.want(code, 400, raw, "explicit category_id 0")

	// Silme ve profil silinince CASCADE.
	code, raw = e.as(alice, "DELETE", fmt.Sprintf("/budgets/%d", tb.ID), nil)
	e.want(code, 204, raw, "delete total")
	code, raw = e.as(alice, "DELETE", fmt.Sprintf("/profiles/%d", home.ID), nil)
	e.want(code, 204, raw, "delete profile")
	var n int
	if err := e.db.QueryRow(`SELECT count(*) FROM expense.budgets WHERE profile_id=$1`, home.ID).Scan(&n); err != nil || n != 0 {
		t.Fatalf("total budget must cascade with profile: n=%d err=%v", n, err)
	}
}

func TestPGVariableRecurringRoundTripProjectionAndBulk(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	fatura := e.cats["Fatura / Abonelik"]
	p := e.profiles(alice)[0]
	e.profiles(bob)

	now := time.Now()
	monthsAgo := func(n int) string { // her zaman ayin 1'i: gelecege/bugune tasmaz
		return time.Date(now.Year(), now.Month()-time.Month(n), 1, 0, 0, 0, 0, time.UTC).Format(dateLayout)
	}
	bill := func(amount float64, date string, extra map[string]any) expenseOut {
		body := map[string]any{
			"date": date, "category_id": fatura, "recurring_day": 20, "recurring_kind": "variable", "recurring_remind": true,
		}
		for k, v := range extra {
			body[k] = v
		}
		return e.create(alice, e.exp("CK Elektrik", amount, p.ID, body))
	}
	first := bill(400, monthsAgo(3), map[string]any{"recurring_estimate": 450})
	bill(500, monthsAgo(2), nil)
	bill(600, monthsAgo(1), nil)

	// Alanlar yazilir ve okunur (tahmin yalnizca degisken faturada saklanir).
	if first.RecurringKind != "variable" || first.RecurringEstimate != 450 {
		t.Fatalf("kind/estimate must round-trip: %+v", first)
	}
	fixed := e.create(alice, e.exp("Ev sahibi", 5000, p.ID, map[string]any{
		"date": monthsAgo(1), "category_id": e.cats["Ev / Yaşam"], "recurring_day": 1, "recurring_kind": "fixed", "recurring_estimate": 999,
	}))
	if fixed.RecurringKind != "fixed" || fixed.RecurringEstimate != 0 {
		t.Fatalf("fixed expenses carry no estimate: %+v", fixed)
	}
	plain := e.create(alice, e.exp("Migros", 50, p.ID, nil))
	if plain.RecurringKind != "fixed" || plain.RecurringEstimate != 0 {
		t.Fatalf("defaults: %+v", plain)
	}

	type resp struct {
		recurringTotals
		Count int            `json:"count"`
		Items []recurringOut `json:"items"`
	}
	get := func(uid int64, q string) resp {
		code, b := e.as(uid, "GET", "/recurring"+q, nil)
		e.want(code, 200, b, "recurring")
		var r resp
		_ = json.Unmarshal(b, &r)
		return r
	}
	r := get(alice, fmt.Sprintf("?profile_id=%d", p.ID))
	var el recurringOut
	for _, it := range r.Items {
		if it.Merchant == "CK Elektrik" {
			el = it
		}
	}
	// Bu ay henuz fatura yok: son 3 ayin ortalamasi (400, 500, 600) ve araligi.
	if el.Kind != "variable" || el.PaidThisMonth || el.ExpectedAmount != 500 || el.MinAmount != 400 || el.MaxAmount != 600 {
		t.Fatalf("unpaid variable bill: %+v", el)
	}
	if r.Count != 2 || r.Monthly != 5500 || r.Remaining != 5500 || r.Paid != 0 {
		t.Fatalf("projection before the new bill: %+v", r)
	}

	// Yeni ayin faturasi eklendi -> otomatik "odendi", projeksiyon gercek tutarla guncellenir.
	bill(520, now.Format(dateLayout), nil)
	r = get(alice, fmt.Sprintf("?profile_id=%d", p.ID))
	for _, it := range r.Items {
		if it.Merchant == "CK Elektrik" {
			el = it
		}
	}
	if !el.PaidThisMonth || el.ActualAmount != 520 || el.MonthAmount != 520 {
		t.Fatalf("new month's bill must mark the item paid: %+v", el)
	}
	if r.Monthly != 5520 || r.Paid != 520 || r.Remaining != 5000 {
		t.Fatalf("projection after the new bill: %+v", r)
	}
	// Baska hesap hicbir sey gormez.
	if b := get(bob, ""); b.Count != 0 || b.Monthly != 0 {
		t.Fatalf("bob sees alice's recurring: %+v", b)
	}

	// Gecersiz tur / tahmin.
	for _, extra := range []map[string]any{{"recurring_kind": "weekly"}, {"recurring_estimate": -5}} {
		code, raw := e.as(alice, "POST", "/expenses", e.exp("X", 1, p.ID, mergeMaps(map[string]any{"recurring_day": 5}, extra)))
		e.want(code, 400, raw, fmt.Sprintf("invalid %v", extra))
	}

	// Cevrimdisi kuyruk (bulk) turu ve tahmini tasir.
	item := e.exp("Su", 120, 0, map[string]any{
		"client_uid": "off-water", "category_id": fatura, "recurring_day": 8, "recurring_kind": "variable", "recurring_estimate": 140,
	})
	code, raw := e.as(alice, "POST", "/expenses/bulk", map[string]any{"profile_id": p.ID, "expenses": []any{item}})
	e.want(code, 200, raw, "bulk")
	var water expenseOut
	for _, x := range e.list(alice, "") {
		if x.Merchant == "Su" {
			water = x
		}
	}
	if water.RecurringKind != "variable" || water.RecurringEstimate != 140 || water.RecurringDay != 8 {
		t.Fatalf("offline-queue upload must keep kind and estimate: %+v", water)
	}
}

func mergeMaps(a, b map[string]any) map[string]any {
	for k, v := range b {
		a[k] = v
	}
	return a
}
