package main

import (
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
)

// Kategori bazli aylik butce limitleri: profil (user_id + profile_id) basina, kategori basina tek limit.
// Harcama, Ozet ekranindaki kategori dagilimiyla ayni sekilde FIS tutari (expenses.amount) uzerinden ve
// fisin kendi kategorisine gore toplanir (kalem kategorileri/indirim ayrica hesaba katilmaz).

const (
	// Butce esikleri: harcama limitin %80'ine ulasinca uyari, %100'une ulasinca/asinca kritik.
	budgetWarnPercent     = 80
	budgetExceededPercent = 100
	maxBudgetLimit        = 1e9
)

type budgetOut struct {
	ID        int64 `json:"id"`
	ProfileID int64 `json:"profile_id"`
	// CategoryID null = profilin TOPLAM aylik butcesi (tum kategorilerin toplami).
	CategoryID   *int      `json:"category_id"`
	CategoryName string    `json:"category_name"`
	MonthlyLimit float64   `json:"monthly_limit"`
	UpdatedAt    time.Time `json:"updated_at"`
	// Spent: istenen ayda (varsayilan bu ay) bu profilde bu kategoriye harcanan tutar.
	Spent float64 `json:"spent"`
	// Status: ok | warning (>= %80) | exceeded (>= %100).
	Status string `json:"status"`
}

// budgetStatus harcama/limit oranini esiklere gore siniflar. Karsilastirma kurus (tamsayi) uzerinden
// yapilir: 79,99 -> ok, 80,00 -> warning, 100,00 -> exceeded (kayan nokta hatasi sinir degerleri kaydirmasin).
func budgetStatus(spent, limit float64) string {
	if limit <= 0 {
		return "ok"
	}
	s := int64(math.Round(spent * 100))
	l := int64(math.Round(limit * 100))
	switch {
	case s*100 >= l*budgetExceededPercent:
		return "exceeded"
	case s*100 >= l*budgetWarnPercent:
		return "warning"
	default:
		return "ok"
	}
}

const selectBudget = `
SELECT b.id, b.profile_id, b.category_id, COALESCE(c.name, 'Toplam bütçe'), b.monthly_limit, b.updated_at,
       COALESCE((SELECT SUM(e.amount) FROM expense.expenses e
                 WHERE e.user_id = b.user_id AND e.profile_id = b.profile_id
                   AND (b.category_id IS NULL OR e.category_id = b.category_id)
                   AND e.spent_at >= $2 AND e.spent_at < $3), 0)
FROM expense.budgets b LEFT JOIN expense.categories c ON c.id = b.category_id `

func scanBudget(s scanner) (budgetOut, error) {
	var b budgetOut
	err := s.Scan(&b.ID, &b.ProfileID, &b.CategoryID, &b.CategoryName, &b.MonthlyLimit, &b.UpdatedAt, &b.Spent)
	b.Spent = math.Round(b.Spent*100) / 100
	b.Status = budgetStatus(b.Spent, b.MonthlyLimit)
	return b, err
}

// monthRange `date` (YYYY-MM-DD, bos = bugun) tarihinin ayini [bas, sonraki ay basi) olarak dondurur.
func monthRange(v string) (time.Time, time.Time, bool) {
	ref := time.Now()
	if v != "" {
		d, err := time.Parse(dateLayout, v)
		if err != nil {
			return time.Time{}, time.Time{}, false
		}
		ref = d
	}
	from := time.Date(ref.Year(), ref.Month(), 1, 0, 0, 0, 0, time.UTC)
	return from, from.AddDate(0, 1, 0), true
}

// listBudgets: profile_id verilirse yalnizca o profilin (sahiplik dogrulanir), verilmezse hesabin tum
// profillerinin limitleri. Baska hesabin verisi hicbir kosulda donmez.
func (h *handler) listBudgets(c *gin.Context) {
	from, to, ok := monthRange(c.Query("date"))
	if !ok {
		badRequest(c, "date must be YYYY-MM-DD")
		return
	}
	userID := c.GetInt64("userID")
	q := selectBudget + `WHERE b.user_id = $1`
	args := []any{userID, from, to}
	if v := c.Query("profile_id"); v != "" {
		pid, ok := h.profileFilter(c, v)
		if !ok {
			return
		}
		args = append(args, pid)
		q += ` AND b.profile_id = $4`
	}
	rows, err := h.db.Query(q+` ORDER BY b.profile_id, (b.category_id IS NOT NULL), c.name`, args...)
	if err != nil {
		serverError(c)
		return
	}
	defer rows.Close()
	out := []budgetOut{}
	for rows.Next() {
		b, err := scanBudget(rows)
		if err != nil {
			serverError(c)
			return
		}
		out = append(out, b)
	}
	if rows.Err() != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, out)
}

// putBudget limiti olusturur ya da gunceller (profil + kategori basina tek satir; category_id yoksa profilin toplam butcesi).
func (h *handler) putBudget(c *gin.Context) {
	var in struct {
		ProfileID int64 `json:"profile_id"`
		// CategoryID yok / null = profilin toplam aylik butcesi.
		CategoryID   *int    `json:"category_id"`
		MonthlyLimit float64 `json:"monthly_limit"`
	}
	if err := c.ShouldBindJSON(&in); err != nil {
		badRequest(c, "invalid request body")
		return
	}
	if math.IsNaN(in.MonthlyLimit) || math.IsInf(in.MonthlyLimit, 0) || in.MonthlyLimit < 0.01 || in.MonthlyLimit >= maxBudgetLimit {
		badRequest(c, "monthly_limit must be a positive number")
		return
	}
	if in.ProfileID < 0 || (in.CategoryID != nil && *in.CategoryID <= 0) {
		badRequest(c, "invalid profile_id or category_id")
		return
	}
	limit := math.Round(in.MonthlyLimit*100) / 100
	userID := c.GetInt64("userID")
	pid, found, err := h.resolveProfile(userID, in.ProfileID)
	if err != nil {
		serverError(c)
		return
	}
	if !found {
		c.JSON(http.StatusNotFound, gin.H{"error": "profile not found"})
		return
	}
	var id int64
	if in.CategoryID == nil {
		// Toplam butce: profil basina tek satir (kismi tekil indeks uq_budgets_total).
		err = h.db.QueryRow(
			`INSERT INTO expense.budgets (user_id, profile_id, category_id, monthly_limit) VALUES ($1,$2,NULL,$3)
			 ON CONFLICT (profile_id) WHERE category_id IS NULL
			 DO UPDATE SET monthly_limit = EXCLUDED.monthly_limit, updated_at = now()
			 RETURNING id`, userID, pid, limit).Scan(&id)
	} else {
		err = h.db.QueryRow(
			`INSERT INTO expense.budgets (user_id, profile_id, category_id, monthly_limit) VALUES ($1,$2,$3,$4)
			 ON CONFLICT (profile_id, category_id) DO UPDATE SET monthly_limit = EXCLUDED.monthly_limit, updated_at = now()
			 RETURNING id`, userID, pid, *in.CategoryID, limit).Scan(&id)
	}
	if isFKViolation(err) {
		badRequest(c, "unknown category_id")
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	from, to, _ := monthRange("")
	b, err := scanBudget(h.db.QueryRow(selectBudget+`WHERE b.id = $1 AND b.user_id = $4`, id, from, to, userID))
	if err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, b)
}

func (h *handler) deleteBudget(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		badRequest(c, "invalid id")
		return
	}
	res, err := h.db.Exec(`DELETE FROM expense.budgets WHERE id = $1 AND user_id = $2`, id, c.GetInt64("userID"))
	if err != nil {
		serverError(c)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "budget not found"})
		return
	}
	c.Status(http.StatusNoContent)
}
