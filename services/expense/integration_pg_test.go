package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/lib/pq"

	"fissio/expense/internal/receiptparse"
)

// Entegrasyon testi (gercek Postgres). YIKICIDIR: expense semasini siler; yalnizca "test" iceren atilabilir bir
// veritabanina karsi calisir: FISSIO_TEST_DATABASE_URL=postgres://.../fissio_test go test -run PG ./...
func TestPGMigrateAndRules(t *testing.T) {
	url := os.Getenv("FISSIO_TEST_DATABASE_URL")
	if url == "" || !strings.Contains(url, "test") {
		t.Skip()
	}
	db, err := sql.Open("postgres", url)
	if err != nil {
		t.Fatal(err)
	}
	// Eski kurulum: eski 8 kategori + Ulasim'a bagli bir harcama.
	for _, q := range []string{
		`DROP SCHEMA IF EXISTS expense CASCADE`,
		`CREATE SCHEMA expense`,
		`CREATE TABLE expense.categories (id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE, keywords TEXT[] NOT NULL DEFAULT '{}')`,
		`CREATE TABLE expense.expenses (id BIGSERIAL PRIMARY KEY, user_id BIGINT NOT NULL, merchant TEXT NOT NULL DEFAULT '', amount NUMERIC(12,2) NOT NULL CHECK (amount > 0), spent_at DATE NOT NULL, category_id INT NOT NULL REFERENCES expense.categories(id), created_at TIMESTAMPTZ NOT NULL DEFAULT now())`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	for _, n := range []string{"Market", "Akaryakıt", "Restoran & Kafe", "Sağlık", "Giyim", "Ulaşım", "Fatura", "Diğer"} {
		kw := []string{}
		if n == "Fatura" {
			kw = []string{"turkcell", "elektrik", "dogalgaz"}
		}
		if _, err := db.Exec(`INSERT INTO expense.categories (name, keywords) VALUES ($1,$2)`, n, pq.Array(kw)); err != nil {
			t.Fatal(err)
		}
	}
	var ulasim int
	_ = db.QueryRow(`SELECT id FROM expense.categories WHERE name='Ulaşım'`).Scan(&ulasim)
	if _, err := db.Exec(`INSERT INTO expense.expenses (user_id, merchant, amount, spent_at, category_id) VALUES (1,'IETT',10,'2026-05-01',$1)`, ulasim); err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 2; i++ { // idempotent: iki kez calisir
		if err := migrate(db); err != nil {
			t.Fatalf("migrate #%d: %v", i+1, err)
		}
	}
	h := &handler{db: db}
	cats, err := h.loadCategories()
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, c := range cats {
		names = append(names, c.Name)
	}
	t.Logf("categories: %v", names)
	if len(cats) != 11 {
		t.Fatalf("want 11 categories, got %d", len(cats))
	}
	var catName string
	if err := db.QueryRow(`SELECT c.name FROM expense.expenses e JOIN expense.categories c ON c.id=e.category_id WHERE merchant='IETT'`).Scan(&catName); err != nil || catName != "Akaryakıt / Ulaşım" {
		t.Fatalf("Ulasim expense moved to %q (%v)", catName, err)
	}
	var kws []string
	_ = db.QueryRow(`SELECT keywords FROM expense.categories WHERE name='Fatura / Abonelik'`).Scan(pq.Array(&kws))
	if len(kws) != 1 || kws[0] != "turkcell" {
		t.Fatalf("elektrik/dogalgaz keywords should be removed: %v", kws)
	}

	// Kural: yaz, guncelle, yukle, sil
	id := func(name string) int {
		for _, c := range cats {
			if c.Name == name {
				return c.ID
			}
		}
		t.Fatalf("no category %s", name)
		return 0
	}
	in := expenseInput{Merchant: "YILDIZ GIDA", CategoryID: id("Eğlence / Hobi"), SuggestedCategoryID: id("Market / Gıda"),
		Items: []expenseItem{{Name: "EKMEK 1ADET", Amount: 5, CategoryID: id("Ev / Yaşam"), SuggestedCategoryID: id("Market / Gıda")}}}
	for i := 0; i < 2; i++ {
		if err := saveRules(db, 42, collectRuleUpdates(in)); err != nil {
			t.Fatalf("saveRules: %v", err)
		}
	}
	rs, err := loadRules(db, 42)
	if err != nil || rs.Merchant["yildiz gida"] != id("Eğlence / Hobi") || rs.Item["ekmek"] != id("Ev / Yaşam") {
		t.Fatalf("rules = %+v %v", rs, err)
	}
	var hits int
	_ = db.QueryRow(`SELECT hits FROM expense.category_rules WHERE user_id=42 AND kind='merchant'`).Scan(&hits)
	if hits != 2 {
		t.Fatalf("hits = %d", hits)
	}
	if other, _ := loadRules(db, 7); len(other.Merchant)+len(other.Item) != 0 {
		t.Fatal("rules must be per-user")
	}
	// Kural sonraki taramada uygulanir.
	now := time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)
	r := receiptparse.ParseWith("YILDIZ GIDA\n12.05.2026\nEKMEK 5,00\nTOPLAM 5,00", cats, now, receiptparse.ParseOptions{Rules: rs})
	if r.CategoryName != "Eğlence / Hobi" || r.CategorySource != "rule" || r.Items[0].CategoryName != "Ev / Yaşam" {
		t.Fatalf("parse with rules: %+v", r)
	}
	// Kullanici basina ust sinir
	for i := 0; i < maxRulesPerUser+5; i++ {
		_ = saveRules(db, 99, []ruleUpdate{{"item", "kural" + string(rune('a'+i%26)) + string(rune('a'+i/26%26)) + string(rune('a'+i/676)), id("Giyim")}})
	}
	var n int
	_ = db.QueryRow(`SELECT count(*) FROM expense.category_rules WHERE user_id=99`).Scan(&n)
	if n != maxRulesPerUser {
		t.Fatalf("cap: %d", n)
	}
}

// TestPGHTTPFlow: kaydet -> kural ogren -> tekrar tara -> kural uygulanir; kalem kategorisi dogrulama.
func TestPGHTTPFlow(t *testing.T) {
	url := os.Getenv("FISSIO_TEST_DATABASE_URL")
	if url == "" || !strings.Contains(url, "test") {
		t.Skip()
	}
	db, err := sql.Open("postgres", url)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`DROP SCHEMA IF EXISTS expense CASCADE`); err != nil {
		t.Fatal(err)
	}
	if err := migrate(db); err != nil {
		t.Fatal(err)
	}
	h := &handler{db: db}
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("userID", int64(1)); c.Next() })
	r.GET("/categories", h.listCategories)
	r.POST("/receipts/parse", h.parseReceipt)
	r.POST("/expenses", h.createExpense)
	r.GET("/expenses", h.listExpenses)
	r.PUT("/expenses/:id", h.updateExpense)
	r.GET("/category-rules", h.listRules)
	r.DELETE("/category-rules/:id", h.deleteRule)

	do := func(method, path, body string) (int, []byte) {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w.Code, w.Body.Bytes()
	}
	catID := map[string]int{}
	_, b := do("GET", "/categories", "")
	var cats []Category
	_ = json.Unmarshal(b, &cats)
	for _, c := range cats {
		catID[c.Name] = c.ID
	}
	text := "YILDIZ GIDA SAN. TIC. LTD.\n12.05.2026\nSUT 1L *34,50\nEKMEK *10,00\nTOPLAM *44,50"
	parse := func() receiptparse.ParseResult {
		pb, _ := json.Marshal(map[string]string{"text": text})
		code, b := do("POST", "/receipts/parse", string(pb))
		if code != 200 {
			t.Fatalf("parse %d %s", code, b)
		}
		var p receiptparse.ParseResult
		_ = json.Unmarshal(b, &p)
		return p
	}
	p := parse()
	if p.CategoryName != "Market / Gıda" || p.CategorySource != "items" || len(p.Items) != 2 || p.Items[0].CategoryName != "Market / Gıda" {
		t.Fatalf("first parse: %+v", p)
	}

	// Kullanici fisi "Eglence / Hobi", EKMEK'i "Ev / Yasam" yapar (onerilenlerden farkli).
	body := func(extra string) string {
		return fmt.Sprintf(`{"merchant":%q,"amount":44.5,"date":"2026-05-12","category_id":%d,"suggested_category_id":%d,"note":"",
		  "items":[{"name":"SUT 1L","amount":34.5,"category_id":%d,"suggested_category_id":%d},
		           {"name":"EKMEK","amount":10,"category_id":%d,"suggested_category_id":%d%s}]}`,
			p.Merchant, catID["Eğlence / Hobi"], p.CategoryID,
			catID["Market / Gıda"], catID["Market / Gıda"], catID["Ev / Yaşam"], catID["Market / Gıda"], extra)
	}
	code, b := do("POST", "/expenses", body(""))
	if code != 201 {
		t.Fatalf("create %d %s", code, b)
	}
	var created expenseOut
	_ = json.Unmarshal(b, &created)
	if created.Items[1].CategoryName != "Ev / Yaşam" || created.Items[0].CategoryID != catID["Market / Gıda"] {
		t.Fatalf("created items: %+v", created.Items)
	}
	// Saklanan JSON yalniz {name, amount, category_id}; oneri/guven alanlari yok.
	var raw string
	_ = db.QueryRow(`SELECT items::text FROM expense.expenses WHERE id=$1`, created.ID).Scan(&raw)
	if strings.Contains(raw, "suggested") || strings.Contains(raw, "confidence") {
		t.Fatalf("stored items leak transient fields: %s", raw)
	}

	// Tekrar tara: kullanici kurallari uygulanir.
	p2 := parse()
	if p2.CategoryName != "Eğlence / Hobi" || p2.CategorySource != "rule" {
		t.Fatalf("receipt rule not applied: %s %s", p2.CategoryName, p2.CategorySource)
	}
	for _, it := range p2.Items {
		if it.Name == "EKMEK" && (it.CategoryName != "Ev / Yaşam" || it.CategorySource != "rule") {
			t.Fatalf("item rule not applied: %+v", it)
		}
		if it.Name == "SUT 1L" && it.CategoryName != "Market / Gıda" {
			t.Fatalf("untouched item changed: %+v", it)
		}
	}

	// Listede kalem kategori adlari dolu.
	code, b = do("GET", "/expenses", "")
	var list []expenseOut
	_ = json.Unmarshal(b, &list)
	if code != 200 || len(list) != 1 || list[0].Items[1].CategoryName != "Ev / Yaşam" {
		t.Fatalf("list %d %s", code, b)
	}

	// Gecersiz kalem kategorisi -> 400, ve hicbir sey yazilmaz.
	if code, _ := do("POST", "/expenses", strings.Replace(body(""), fmt.Sprintf(`"category_id":%d,"suggested_category_id":%d}`, catID["Ev / Yaşam"], catID["Market / Gıda"]), `"category_id":9999}`, 1)); code != 400 {
		t.Fatalf("unknown item category: %d", code)
	}
	var n int
	_ = db.QueryRow(`SELECT count(*) FROM expense.expenses`).Scan(&n)
	if n != 1 {
		t.Fatalf("expenses = %d", n)
	}

	// Guncelleme de ogrenir; sonra kural silinir ve artik uygulanmaz.
	if code, b := do("PUT", fmt.Sprintf("/expenses/%d", created.ID), body("")); code != 200 {
		t.Fatalf("update %d %s", code, b)
	}
	code, b = do("GET", "/category-rules", "")
	var rules []categoryRuleOut
	_ = json.Unmarshal(b, &rules)
	if code != 200 || len(rules) != 2 {
		t.Fatalf("rules %d %s", code, b)
	}
	for _, ru := range rules {
		if code, _ := do("DELETE", fmt.Sprintf("/category-rules/%d", ru.ID), ""); code != 204 {
			t.Fatalf("delete rule %d", code)
		}
	}
	if code, _ := do("DELETE", "/category-rules/123456", ""); code != 404 {
		t.Fatalf("delete missing: %d", code)
	}
	if p3 := parse(); p3.CategoryName != "Market / Gıda" {
		t.Fatalf("after delete: %s", p3.CategoryName)
	}
}
