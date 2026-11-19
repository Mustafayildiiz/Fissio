package main

import (
	"database/sql"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"

	"fissio/expense/internal/receiptparse"
)

// Kullanicinin kategori duzeltmelerinden ogrenilen kisisel kurallar (expense.category_rules).
// Kural anahtari receiptparse.NormalizeKey/MerchantKey ile uretilir; fis/kalem ayristirilirken
// receiptparse.RuleSet olarak ParseWith'e girer.

// maxRulesPerUser: kullanici basina tutulan en fazla kural (en eskiler silinir).
const maxRulesPerUser = 2000

type queryer interface {
	Query(query string, args ...any) (*sql.Rows, error)
}

type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

func loadRules(q queryer, userID int64) (receiptparse.RuleSet, error) {
	rs := receiptparse.RuleSet{Merchant: map[string]int{}, Item: map[string]int{}}
	rows, err := q.Query(`SELECT kind, pattern, category_id FROM expense.category_rules WHERE user_id = $1`, userID)
	if err != nil {
		return rs, err
	}
	defer rows.Close()
	for rows.Next() {
		var kind, pattern string
		var cat int
		if err := rows.Scan(&kind, &pattern, &cat); err != nil {
			return rs, err
		}
		if kind == "merchant" {
			rs.Merchant[pattern] = cat
		} else {
			rs.Item[pattern] = cat
		}
	}
	return rs, rows.Err()
}

// saveRules kural guncellemelerini yazar (ayni anahtar varsa kategori guncellenir, hits artar) ve
// kullanici basina en fazla maxRulesPerUser kural tutar (en eskiler silinir).
func saveRules(db execer, userID int64, updates []ruleUpdate) error {
	if len(updates) == 0 {
		return nil
	}
	for _, u := range updates {
		if _, err := db.Exec(
			`INSERT INTO expense.category_rules (user_id, kind, pattern, category_id)
			 VALUES ($1,$2,$3,$4)
			 ON CONFLICT (user_id, kind, pattern)
			 DO UPDATE SET category_id = EXCLUDED.category_id, hits = expense.category_rules.hits + 1, updated_at = now()`,
			userID, u.Kind, u.Pattern, u.CategoryID); err != nil {
			return err
		}
	}
	_, err := db.Exec(
		`DELETE FROM expense.category_rules WHERE user_id = $1 AND id IN (
		   SELECT id FROM expense.category_rules WHERE user_id = $1 ORDER BY updated_at DESC, id DESC OFFSET $2)`,
		userID, maxRulesPerUser)
	return err
}

// ruleUpdate bir kullanici duzeltmesinden turetilen kural yazimidir.
type ruleUpdate struct {
	Kind       string // "merchant" | "item"
	Pattern    string // receiptparse.NormalizeKey / MerchantKey sonucu
	CategoryID int
}

// collectRuleUpdates, kullanicinin onerilen kategoriyi degistirdigi fis/kalemler icin kural uretir.
// Yalnizca oneri (suggested_category_id) verilmis VE secilenden farkliysa kural yazilir; onaylanan
// oneriler ve elle (onerisiz) secimler kural uretmez.
func collectRuleUpdates(in expenseInput) []ruleUpdate {
	var out []ruleUpdate
	if in.SuggestedCategoryID > 0 && in.CategoryID > 0 && in.SuggestedCategoryID != in.CategoryID {
		if k := receiptparse.MerchantKey(in.Merchant); k != "" {
			out = append(out, ruleUpdate{"merchant", k, in.CategoryID})
		}
	}
	seen := map[string]bool{}
	for _, it := range in.Items {
		if it.SuggestedCategoryID > 0 && it.CategoryID > 0 && it.SuggestedCategoryID != it.CategoryID {
			if k := receiptparse.NormalizeKey(it.Name); k != "" && !seen[k] {
				seen[k] = true
				out = append(out, ruleUpdate{"item", k, it.CategoryID})
			}
		}
	}
	return out
}

type categoryRuleOut struct {
	ID           int64     `json:"id"`
	Kind         string    `json:"kind"`
	Pattern      string    `json:"pattern"`
	CategoryID   int       `json:"category_id"`
	CategoryName string    `json:"category_name"`
	Hits         int       `json:"hits"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// listRules: kullanicinin ogrenilmis kategori kurallari (en yeni once).
func (h *handler) listRules(c *gin.Context) {
	rows, err := h.db.Query(
		`SELECT r.id, r.kind, r.pattern, r.category_id, c.name, r.hits, r.updated_at
		 FROM expense.category_rules r JOIN expense.categories c ON c.id = r.category_id
		 WHERE r.user_id = $1 ORDER BY r.updated_at DESC, r.id DESC LIMIT 500`, c.GetInt64("userID"))
	if err != nil {
		serverError(c)
		return
	}
	defer rows.Close()
	out := []categoryRuleOut{}
	for rows.Next() {
		var r categoryRuleOut
		if err := rows.Scan(&r.ID, &r.Kind, &r.Pattern, &r.CategoryID, &r.CategoryName, &r.Hits, &r.UpdatedAt); err != nil {
			serverError(c)
			return
		}
		out = append(out, r)
	}
	if rows.Err() != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, out)
}

// deleteRule: yalnizca kullanicinin kendi kurali silinebilir.
func (h *handler) deleteRule(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		badRequest(c, "invalid id")
		return
	}
	res, err := h.db.Exec(`DELETE FROM expense.category_rules WHERE id = $1 AND user_id = $2`, id, c.GetInt64("userID"))
	if err != nil {
		serverError(c)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "rule not found"})
		return
	}
	c.Status(http.StatusNoContent)
}
