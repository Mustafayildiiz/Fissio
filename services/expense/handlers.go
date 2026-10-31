package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/lib/pq"
)

type handler struct{ db *sql.DB }

const dateLayout = "2006-01-02"

func badRequest(c *gin.Context, msg string) { c.JSON(http.StatusBadRequest, gin.H{"error": msg}) }
func serverError(c *gin.Context)            { c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"}) }

func (h *handler) loadCategories() ([]Category, error) {
	rows, err := h.db.Query(`SELECT id, name, keywords FROM expense.categories ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cats := []Category{}
	for rows.Next() {
		var c Category
		if err := rows.Scan(&c.ID, &c.Name, pq.Array(&c.Keywords)); err != nil {
			return nil, err
		}
		cats = append(cats, c)
	}
	return cats, rows.Err()
}

func (h *handler) listCategories(c *gin.Context) {
	cats, err := h.loadCategories()
	if err != nil {
		serverError(c)
		return
	}
	for i := range cats {
		cats[i].Keywords = nil // istemcinin anahtar kelimelere ihtiyaci yok
	}
	c.JSON(http.StatusOK, cats)
}

// parseReceipt: FR-2.4 / FR-3.1 / FR-3.2 - OCR'dan gelen ham metni ayristirir. Hicbir sey saklanmaz.
func (h *handler) parseReceipt(c *gin.Context) {
	var in struct {
		Text string `json:"text"`
	}
	if err := c.ShouldBindJSON(&in); err != nil {
		badRequest(c, "invalid request body")
		return
	}
	if len(in.Text) == 0 || len(in.Text) > 20000 {
		badRequest(c, "text must be between 1 and 20000 bytes")
		return
	}
	cats, err := h.loadCategories()
	if err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, Parse(in.Text, cats, time.Now()))
}

type expenseItem struct {
	Name   string  `json:"name"`
	Amount float64 `json:"amount"`
}

type expenseInput struct {
	Merchant   string        `json:"merchant"`
	Amount     float64       `json:"amount"`
	Date       string        `json:"date"`
	CategoryID int           `json:"category_id"`
	Note       string        `json:"note"`
	Items      []expenseItem `json:"items"`
}

type expenseOut struct {
	ID           int64         `json:"id"`
	Merchant     string        `json:"merchant"`
	Amount       float64       `json:"amount"`
	Date         string        `json:"date"`
	CategoryID   int           `json:"category_id"`
	CategoryName string        `json:"category_name"`
	Note         string        `json:"note"`
	Items        []expenseItem `json:"items"`
}

func (in *expenseInput) validate() (time.Time, string) {
	if math.IsNaN(in.Amount) || math.IsInf(in.Amount, 0) || in.Amount <= 0 || in.Amount >= 1e10 {
		return time.Time{}, "amount must be a positive number"
	}
	in.Amount = math.Round(in.Amount*100) / 100
	if in.Amount <= 0 {
		return time.Time{}, "amount must be at least 0.01"
	}
	d, err := time.Parse(dateLayout, in.Date)
	if err != nil {
		return time.Time{}, "date must be YYYY-MM-DD"
	}
	if len([]rune(in.Merchant)) > 100 {
		return time.Time{}, "merchant too long"
	}
	if len([]rune(in.Note)) > 500 {
		return time.Time{}, "note too long"
	}
	if len(in.Items) > 100 {
		return time.Time{}, "too many items"
	}
	for i := range in.Items {
		it := &in.Items[i]
		if len([]rune(it.Name)) > 100 || math.IsNaN(it.Amount) || math.IsInf(it.Amount, 0) || it.Amount < 0 || it.Amount >= 1e10 {
			return time.Time{}, "invalid item"
		}
		it.Amount = math.Round(it.Amount*100) / 100
	}
	if in.Items == nil {
		in.Items = []expenseItem{}
	}
	return d, ""
}

func isFKViolation(err error) bool {
	var pqErr *pq.Error
	return errors.As(err, &pqErr) && pqErr.Code == "23503"
}

const selectExpense = `
SELECT e.id, e.merchant, e.amount, e.spent_at, e.category_id, c.name, e.note, e.items
FROM expense.expenses e JOIN expense.categories c ON c.id = e.category_id `

type scanner interface{ Scan(dest ...any) error }

func scanExpense(s scanner) (expenseOut, error) {
	var e expenseOut
	var d time.Time
	var items []byte
	err := s.Scan(&e.ID, &e.Merchant, &e.Amount, &d, &e.CategoryID, &e.CategoryName, &e.Note, &items)
	e.Date = d.Format(dateLayout)
	e.Items = []expenseItem{}
	if err == nil && len(items) > 0 {
		_ = json.Unmarshal(items, &e.Items)
	}
	return e, err
}

func (h *handler) createExpense(c *gin.Context) {
	var in expenseInput
	if err := c.ShouldBindJSON(&in); err != nil {
		badRequest(c, "invalid request body")
		return
	}
	d, msg := in.validate()
	if msg != "" {
		badRequest(c, msg)
		return
	}
	itemsJSON, _ := json.Marshal(in.Items)
	var id int64
	err := h.db.QueryRow(
		`INSERT INTO expense.expenses (user_id, merchant, amount, spent_at, category_id, note, items)
		 VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
		c.GetInt64("userID"), in.Merchant, in.Amount, d, in.CategoryID, in.Note, string(itemsJSON)).Scan(&id)
	if isFKViolation(err) {
		badRequest(c, "unknown category_id")
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	h.respondExpense(c, http.StatusCreated, id)
}

func (h *handler) respondExpense(c *gin.Context, status int, id int64) {
	e, err := scanExpense(h.db.QueryRow(selectExpense+`WHERE e.id = $1 AND e.user_id = $2`, id, c.GetInt64("userID")))
	if errors.Is(err, sql.ErrNoRows) {
		c.JSON(http.StatusNotFound, gin.H{"error": "expense not found"})
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	c.JSON(status, e)
}

func (h *handler) getExpense(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		badRequest(c, "invalid id")
		return
	}
	h.respondExpense(c, http.StatusOK, id)
}

func (h *handler) listExpenses(c *gin.Context) {
	q := selectExpense + `WHERE e.user_id = $1`
	args := []any{c.GetInt64("userID")}
	for _, p := range []struct{ param, op string }{{"from", ">="}, {"to", "<="}} {
		if v := c.Query(p.param); v != "" {
			d, err := time.Parse(dateLayout, v)
			if err != nil {
				badRequest(c, p.param+" must be YYYY-MM-DD")
				return
			}
			args = append(args, d)
			q += ` AND e.spent_at ` + p.op + ` $` + strconv.Itoa(len(args))
		}
	}
	limit, offset := 50, 0
	if v, err := strconv.Atoi(c.Query("limit")); err == nil && v > 0 && v <= 200 {
		limit = v
	}
	if v, err := strconv.Atoi(c.Query("offset")); err == nil && v > 0 {
		offset = v
	}
	args = append(args, limit, offset)
	q += ` ORDER BY e.spent_at DESC, e.id DESC LIMIT $` + strconv.Itoa(len(args)-1) + ` OFFSET $` + strconv.Itoa(len(args))

	rows, err := h.db.Query(q, args...)
	if err != nil {
		serverError(c)
		return
	}
	defer rows.Close()
	out := []expenseOut{}
	for rows.Next() {
		e, err := scanExpense(rows)
		if err != nil {
			serverError(c)
			return
		}
		out = append(out, e)
	}
	if rows.Err() != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, out)
}

func (h *handler) updateExpense(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		badRequest(c, "invalid id")
		return
	}
	var in expenseInput
	if err := c.ShouldBindJSON(&in); err != nil {
		badRequest(c, "invalid request body")
		return
	}
	d, msg := in.validate()
	if msg != "" {
		badRequest(c, msg)
		return
	}
	itemsJSON, _ := json.Marshal(in.Items)
	res, err := h.db.Exec(
		`UPDATE expense.expenses SET merchant=$1, amount=$2, spent_at=$3, category_id=$4, note=$5, items=$6
		 WHERE id=$7 AND user_id=$8`,
		in.Merchant, in.Amount, d, in.CategoryID, in.Note, string(itemsJSON), id, c.GetInt64("userID"))
	if isFKViolation(err) {
		badRequest(c, "unknown category_id")
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "expense not found"})
		return
	}
	h.respondExpense(c, http.StatusOK, id)
}

func (h *handler) deleteExpense(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		badRequest(c, "invalid id")
		return
	}
	res, err := h.db.Exec(`DELETE FROM expense.expenses WHERE id=$1 AND user_id=$2`, id, c.GetInt64("userID"))
	if err != nil {
		serverError(c)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "expense not found"})
		return
	}
	c.Status(http.StatusNoContent)
}

// summary: FR-4.3 - haftalik (Pazartesi baslangicli) veya aylik kategori dagilimi.
func (h *handler) summary(c *gin.Context) {
	period := c.DefaultQuery("period", "month")
	ref := time.Now()
	if v := c.Query("date"); v != "" {
		d, err := time.Parse(dateLayout, v)
		if err != nil {
			badRequest(c, "date must be YYYY-MM-DD")
			return
		}
		ref = d
	}
	ref = time.Date(ref.Year(), ref.Month(), ref.Day(), 0, 0, 0, 0, time.UTC)

	var from, to time.Time
	switch period {
	case "week":
		offset := (int(ref.Weekday()) + 6) % 7 // Pazartesi = 0
		from = ref.AddDate(0, 0, -offset)
		to = from.AddDate(0, 0, 6)
	case "month":
		from = time.Date(ref.Year(), ref.Month(), 1, 0, 0, 0, 0, time.UTC)
		to = from.AddDate(0, 1, -1)
	default:
		badRequest(c, "period must be week or month")
		return
	}

	rows, err := h.db.Query(
		`SELECT c.id, c.name, SUM(e.amount), COUNT(*)
		 FROM expense.expenses e JOIN expense.categories c ON c.id = e.category_id
		 WHERE e.user_id = $1 AND e.spent_at BETWEEN $2 AND $3
		 GROUP BY c.id, c.name ORDER BY SUM(e.amount) DESC`,
		c.GetInt64("userID"), from, to)
	if err != nil {
		serverError(c)
		return
	}
	defer rows.Close()

	type item struct {
		CategoryID int     `json:"category_id"`
		Name       string  `json:"name"`
		Total      float64 `json:"total"`
		Count      int     `json:"count"`
		Percent    float64 `json:"percent"`
	}
	items := []item{}
	total, count := 0.0, 0
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.CategoryID, &it.Name, &it.Total, &it.Count); err != nil {
			serverError(c)
			return
		}
		total += it.Total
		count += it.Count
		items = append(items, it)
	}
	if rows.Err() != nil {
		serverError(c)
		return
	}
	for i := range items {
		if total > 0 {
			items[i].Percent = math.Round(items[i].Total/total*1000) / 10
		}
	}
	c.JSON(http.StatusOK, gin.H{
		"period":      period,
		"from":        from.Format(dateLayout),
		"to":          to.Format(dateLayout),
		"total":       math.Round(total*100) / 100,
		"count":       count,
		"by_category": items,
	})
}

