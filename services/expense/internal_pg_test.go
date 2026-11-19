package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sort"
	"testing"
)

// Hesap verisi silme (auth -> expense internal API). YIKICIDIR: yalnizca atilabilir test veritabaninda calisir
// (bkz. isolation_pg_test.go).

func (e *xenv) countRows(table string, uid int64) int {
	e.t.Helper()
	var n int
	if err := e.db.QueryRow(fmt.Sprintf(`SELECT count(*) FROM expense.%s WHERE user_id = $1`, table), uid).Scan(&n); err != nil {
		e.t.Fatalf("count %s: %v", table, err)
	}
	return n
}

// TestPGUserOwnedTablesAreAllPurged: expense semasinda `user_id` tasiyan her tablo userOwnedTables listesinde olmali
// (yeni tablo eklenip silme listesine unutulursa hesap silme veriyi sessizce birakirdi) ve listedeki her tablo
// gercekten var olmali (yeniden adlandirma sessizce atlanmasin).
func TestPGUserOwnedTablesAreAllPurged(t *testing.T) {
	e := newXEnv(t)
	rows, err := e.db.Query(`SELECT table_name FROM information_schema.columns
		WHERE table_schema = 'expense' AND column_name = 'user_id' ORDER BY table_name`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	inDB := map[string]bool{}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		inDB[name] = true
	}
	listed := map[string]bool{}
	for _, name := range userOwnedTables {
		listed[name] = true
		if !inDB[name] {
			t.Errorf("userOwnedTables lists %q but expense.%s has no user_id column (renamed/removed?)", name, name)
		}
	}
	var missing []string
	for name := range inDB {
		if !listed[name] {
			missing = append(missing, name)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("expense tables with user_id missing from userOwnedTables (account deletion would leave data behind): %v", missing)
	}
}

func TestPGPurgeUserRemovesOnlyThatUsersData(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	market, cafe := e.cats["Market / Gıda"], e.cats["Restoran / Kafe"]

	seed := func(uid int64) {
		p := e.profiles(uid)[0]
		// Ogrenilmis kural: onerilen kategori kaydedilenden farkli.
		ex := e.create(uid, e.exp("BIM", 50, p.ID, map[string]any{"suggested_category_id": cafe}))
		code, b := e.upload(uid, ex.ID)
		e.want(code, 201, b, "upload image")
		code, _, raw := e.putBudget(uid, p.ID, market, 8000)
		e.want(code, 200, raw, "put budget")
	}
	seed(alice)
	seed(bob)
	for _, table := range userOwnedTables {
		if e.countRows(table, alice) == 0 || e.countRows(table, bob) == 0 {
			t.Fatalf("seed did not populate expense.%s for both users", table)
		}
	}

	if err := purgeUser(e.db, alice); err != nil {
		t.Fatalf("purge: %v", err)
	}
	for _, table := range userOwnedTables {
		if n := e.countRows(table, alice); n != 0 {
			t.Errorf("expense.%s still has %d rows for the purged user", table, n)
		}
		if n := e.countRows(table, bob); n == 0 {
			t.Errorf("expense.%s lost the OTHER user's rows", table)
		}
	}
	// Idempotent: ikinci cagri hata vermez.
	if err := purgeUser(e.db, alice); err != nil {
		t.Fatalf("second purge: %v", err)
	}
}

func TestPGInternalPurgeEndpoint(t *testing.T) {
	e := newXEnv(t)
	const alice = int64(1)
	e.create(alice, e.exp("BIM", 50, e.profiles(alice)[0].ID, nil))
	r := buildInternalRouter(e.h, testInternalToken)

	do := func(method, path, token string) int {
		req := httptest.NewRequest(method, path, nil)
		if token != "" {
			req.Header.Set(internalTokenHeader, token)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w.Code
	}
	if c := do("DELETE", fmt.Sprintf("/internal/users/%d", alice), ""); c != http.StatusUnauthorized {
		t.Fatalf("no token: %d", c)
	}
	if c := do("DELETE", fmt.Sprintf("/internal/users/%d", alice), "wrong"); c != http.StatusUnauthorized {
		t.Fatalf("wrong token: %d", c)
	}
	if e.countRows("expenses", alice) == 0 {
		t.Fatal("unauthorized call must not delete anything")
	}
	if c := do("DELETE", "/internal/users/abc", testInternalToken); c != http.StatusBadRequest {
		t.Fatalf("bad id: %d", c)
	}
	if c := do("DELETE", fmt.Sprintf("/internal/users/%d", alice), testInternalToken); c != http.StatusNoContent {
		t.Fatalf("purge: %d", c)
	}
	for _, table := range userOwnedTables {
		if n := e.countRows(table, alice); n != 0 {
			t.Errorf("expense.%s still has %d rows", table, n)
		}
	}
	// Bos token yapilandirmasi tum istekleri reddeder.
	empty := buildInternalRouter(e.h, "")
	req := httptest.NewRequest("DELETE", "/internal/users/1", nil)
	w := httptest.NewRecorder()
	empty.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("empty token config must reject: %d", w.Code)
	}
}

// NUL/kontrol karakterleri validate() tarafindan ayiklanir (Postgres text'te NUL'u reddederdi).
func TestPGBulkStripsNULAndControlChars(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	good := func(uid string) map[string]any { return e.exp("A101", 10, 0, map[string]any{"client_uid": uid}) }
	nul := good("nul-1")
	nul["merchant"] = "BIM\x00MARKET"
	nul["note"] = "not\x01\x02"
	nul["items"] = []any{map[string]any{"name": "SUT\x00", "amount": 5.0}}
	body := map[string]any{"expenses": []any{good("ok-1"), nul, good("ok-2")}}
	code, b := e.as(u, "POST", "/expenses/bulk", body)
	e.want(code, 200, b, "bulk with NUL merchant")
	got := e.list(u, "")
	if len(got) != 3 {
		t.Fatalf("all 3 receipts should be saved (NUL stripped): %d", len(got))
	}
	for _, x := range got {
		if x.ClientUID == "nul-1" && (x.Merchant != "BIMMARKET" || x.Note != "not" || x.Items[0].Name != "SUT") {
			t.Fatalf("control chars must be stripped, got %+v", x)
		}
	}
}

// DB'nin reddettigi bir fis (burada: bir tetikleyici fis "POISON" saticisini reddeder; gercekte bozuk/beklenmedik
// veri) tum bulk partisini 500'e dusurmez: yalniz o fis "error" olur, digerleri yazilir (SAVEPOINT).
func TestPGBulkPoisonItemDoesNotBlockBatch(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	for _, q := range []string{
		`CREATE FUNCTION expense.reject_poison() RETURNS trigger AS $$
		 BEGIN
		   IF NEW.merchant = 'POISON' THEN RAISE EXCEPTION 'rejected' USING ERRCODE = '22023'; END IF;
		   RETURN NEW;
		 END $$ LANGUAGE plpgsql`,
		`CREATE TRIGGER trg_poison BEFORE INSERT ON expense.expenses FOR EACH ROW EXECUTE FUNCTION expense.reject_poison()`,
	} {
		if _, err := e.db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	good := func(uid string) map[string]any { return e.exp("A101", 10, 0, map[string]any{"client_uid": uid}) }
	poison := e.exp("POISON", 10, 0, map[string]any{"client_uid": "poison-1"})
	body := map[string]any{"expenses": []any{good("ok-1"), poison, good("ok-2")}}
	code, b := e.as(u, "POST", "/expenses/bulk", body)
	e.want(code, 200, b, "bulk with poison item")
	var res bulkResp
	if err := json.Unmarshal(b, &res); err != nil {
		t.Fatal(err)
	}
	if res.Created != 2 || res.Failed != 1 || res.Results[1].Status != "error" {
		t.Fatalf("poison item must fail alone: %+v", res)
	}
	if got := e.list(u, ""); len(got) != 2 {
		t.Fatalf("the two valid receipts must be saved: %d", len(got))
	}
	// Ayni parti tekrar gonderilince: gecerliler "skipped", bozuk yine "error" (kuyruk kilitlenmez).
	code, b = e.as(u, "POST", "/expenses/bulk", body)
	e.want(code, 200, b, "retry")
	_ = json.Unmarshal(b, &res)
	if res.Created != 0 || res.Skipped != 2 || res.Failed != 1 {
		t.Fatalf("retry: %+v", res)
	}
}

type bulkResp struct {
	Created int          `json:"created"`
	Skipped int          `json:"skipped"`
	Failed  int          `json:"failed"`
	Results []bulkResult `json:"results"`
}
