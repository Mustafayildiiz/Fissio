package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/lib/pq"
)

type handler struct {
	db         *sql.DB
	ocrFactory *OcrEngineFactory
}

const dateLayout = "2006-01-02"

func badRequest(c *gin.Context, msg string) { c.JSON(http.StatusBadRequest, gin.H{"error": msg}) }
func serverError(c *gin.Context) {
	c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
}

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
	rules, err := loadRules(h.db, c.GetInt64("userID"))
	if err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, ParseWith(in.Text, cats, time.Now(), ParseOptions{Rules: rules}))
}

// scanReceipt: Resolves the active OcrEngine via Strategy Factory, extracts text from
// the receipt image in memory, and parses structured receipt fields.
func (h *handler) scanReceipt(c *gin.Context) {
	// multipart/form-data: tekrarlanabilir "file" (sayfa, <= 6 adet, her biri <= 5MB) ve istege bagli
	// "engine". Uzun fisler birden cok fotografla gelir; sayfalar sirayla OCR'lanir, metinler
	// birlestirilir ve TEK kez ayristirilir.
	files, ok := limitBody(c)
	if !ok {
		return
	}
	if len(files) == 0 {
		badRequest(c, "multipart field 'file' is required")
		return
	}
	if len(files) > maxScanPages {
		badRequest(c, "too many pages (max 6)")
		return
	}
	pages := make([][]byte, 0, len(files))
	for _, fh := range files {
		if fh.Size == 0 || fh.Size > maxImageBytes {
			badRequest(c, "each file is required and must be under 5MB")
			return
		}
		data, err := readImage(fh)
		if err != nil || len(data) == 0 {
			badRequest(c, "invalid file")
			return
		}
		pages = append(pages, data)
	}

	requestedEngine := c.PostForm("engine")
	if requestedEngine == "" {
		requestedEngine = c.Query("engine")
	}
	if requestedEngine == "" {
		requestedEngine = c.GetHeader("X-OCR-Engine")
	}

	factory := h.ocrFactory
	if factory == nil {
		factory = NewOcrEngineFactoryFromEnv()
	}
	engine, err := factory.Resolve(requestedEngine)
	if err != nil {
		badRequest(c, err.Error())
		return
	}

	var texts []string
	agg := OcrExtractionResult{PageCount: len(pages)}
	confSum := 0.0
	for i, img := range pages {
		res, err := engine.ExtractText(c.Request.Context(), img)
		// Bellekten goruntu verisini hemen temizle (FR-2.3 / NFR-2)
		clear(img)
		if err != nil {
			if errors.Is(err, ErrInvalidOcrInput) {
				badRequest(c, "invalid receipt image")
				return
			}
			c.JSON(http.StatusBadGateway, gin.H{"error": err.Error()})
			return
		}
		texts = append(texts, res.RawText)
		agg.Blocks = append(agg.Blocks, res.Blocks...)
		agg.ElapsedMs += res.ElapsedMs
		confSum += res.Confidence
		if i == 0 {
			agg.Engine, agg.ModelVersion = res.Engine, res.ModelVersion
		}
	}
	agg.RawText = mergePageTexts(texts)
	agg.Confidence = confSum / float64(len(pages))
	agg.IsEmpty = strings.TrimSpace(agg.RawText) == ""
	if agg.Blocks == nil {
		agg.Blocks = []OcrTextBlock{}
	}

	cats, err := h.loadCategories()
	if err != nil {
		serverError(c)
		return
	}

	rules, err := loadRules(h.db, c.GetInt64("userID"))
	if err != nil {
		serverError(c)
		return
	}
	parsed := ParseWith(agg.RawText, cats, time.Now(), ParseOptions{Rules: rules})
	c.JSON(http.StatusOK, gin.H{
		"ocr":    agg,
		"parsed": parsed,
	})
}

// expenseItem hem ayristirma ciktisinin hem istegin hem de JSONB'nin kalem tipidir. Kategori alanlari
// opsiyoneldir (eski satirlar sifir degerle okunur). Yalnizca {name, amount, category_id} saklanir
// (bkz. itemsForStorage); guven/kaynak/inceleme alanlari ayristirma ciktisina, suggested_category_id
// yalnizca istege aittir (kullanici duzeltmesinden kural ogrenmek icin).
type expenseItem struct {
	Name               string  `json:"name"`
	Amount             float64 `json:"amount"`
	CategoryID         int     `json:"category_id,omitempty"`
	CategoryName       string  `json:"category_name,omitempty"`
	CategoryConfidence float64 `json:"category_confidence,omitempty"`
	CategorySource     string  `json:"category_source,omitempty"`
	CategoryReview     bool    `json:"category_review,omitempty"`

	SuggestedCategoryID int `json:"suggested_category_id,omitempty"`
}

type expenseInput struct {
	Merchant   string        `json:"merchant"`
	Amount     float64       `json:"amount"`
	Date       string        `json:"date"`
	CategoryID int           `json:"category_id"`
	Note       string        `json:"note"`
	Items      []expenseItem `json:"items"`
	// SuggestedCategoryID: tarama sirasinda otomatik onerilen fis kategorisi. Secilenden farkliysa
	// kullanici duzeltmesi sayilir ve kisisel kural olarak ogrenilir.
	SuggestedCategoryID int `json:"suggested_category_id"`
	// ProfileID: fisin ait oldugu profil (hesabin kendi profili olmali). Bos/0 = varsayilan profil.
	ProfileID int64 `json:"profile_id"`
	// ClientUID: istemcinin urettigi kalici kimlik. Ayni (hesap, client_uid) tekrar gelirse kayit
	// mukerrer olusmaz (cevrimdisi kuyruk tekrari, yedekten iceri aktarma). Bos ise sunucu uretir.
	ClientUID string `json:"client_uid"`
	// RecurringDay: "Her ay tekrarlanir" isareti; 1-31 aylik odeme gunu, 0/yok = tekrarlamaz (bkz. recurring.go).
	RecurringDay int `json:"recurring_day"`
	// RecurringRemind: odeme hatirlaticisi tercihi; verilmezse true.
	RecurringRemind *bool `json:"recurring_remind"`
	// RecurringKind: "fixed" (her ay ayni tutar: kira, abonelik) | "variable" (tutar degisir: elektrik, su,
	// dogalgaz faturasi); bos = fixed.
	RecurringKind string `json:"recurring_kind"`
	// RecurringEstimate: degisken fatura icin kullanicinin tahmini aylik tutari (gecmis fatura yokken
	// projeksiyonda kullanilir); 0/yok = tahmin yok.
	RecurringEstimate float64 `json:"recurring_estimate"`
}

// remind hatirlatici tercihini dondurur (verilmediyse varsayilan: acik).
func (in *expenseInput) remind() bool { return in.RecurringRemind == nil || *in.RecurringRemind }

// recurringArg SQL parametresi: tekrarlamayan fisler icin NULL.
func (in *expenseInput) recurringArg() any {
	if in.RecurringDay == 0 {
		return nil
	}
	return in.RecurringDay
}

// kind tekrar turunu dondurur: yalnizca "variable" degisken, digerleri sabit.
func (in *expenseInput) kind() string {
	if in.RecurringKind == recurringVariable {
		return recurringVariable
	}
	return recurringFixed
}

// estimateArg SQL parametresi: yalnizca tekrarlayan DEGISKEN faturada ve tahmin verildiyse dolu, aksi halde NULL.
func (in *expenseInput) estimateArg() any {
	if in.RecurringDay == 0 || in.kind() != recurringVariable || in.RecurringEstimate <= 0 {
		return nil
	}
	return in.RecurringEstimate
}

// itemsForStorage kalemleri kalici biciminde ({name, amount, category_id}) dondurur.
func itemsForStorage(items []expenseItem) []expenseItem {
	out := make([]expenseItem, len(items))
	for i, it := range items {
		out[i] = expenseItem{Name: it.Name, Amount: it.Amount, CategoryID: it.CategoryID}
	}
	return out
}

// itemCategoriesValid: kalem kategori id'leri (0 = atanmamis) mevcut kategorilerden biri olmali.
func itemCategoriesValid(items []expenseItem, cats []Category) bool {
	known := map[int]bool{}
	for _, c := range cats {
		known[c.ID] = true
	}
	for _, it := range items {
		if it.CategoryID != 0 && !known[it.CategoryID] {
			return false
		}
	}
	return true
}

// fillItemCategories kalemlerin category_name alanini kategori tablosundan doldurur.
func (h *handler) fillItemCategories(out []expenseOut) error {
	need := false
	for _, e := range out {
		for _, it := range e.Items {
			if it.CategoryID != 0 {
				need = true
			}
		}
	}
	if !need {
		return nil
	}
	cats, err := h.loadCategories()
	if err != nil {
		return err
	}
	names := map[int]string{}
	for _, c := range cats {
		names[c.ID] = c.Name
	}
	for i := range out {
		for j := range out[i].Items {
			out[i].Items[j].CategoryName = names[out[i].Items[j].CategoryID]
		}
	}
	return nil
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
	ImageIDs     []int64       `json:"image_ids"`
	ProfileID    int64         `json:"profile_id"`
	ClientUID    string        `json:"client_uid"`
	// RecurringDay 0 = tekrarlamaz.
	RecurringDay    int  `json:"recurring_day"`
	RecurringRemind bool `json:"recurring_remind"`
	// RecurringKind fixed | variable; RecurringEstimate degisken faturanin tahmini tutari (0 = yok).
	RecurringKind     string  `json:"recurring_kind"`
	RecurringEstimate float64 `json:"recurring_estimate"`
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
	if in.ClientUID != "" && !clientUIDRe.MatchString(in.ClientUID) {
		return time.Time{}, "invalid client_uid"
	}
	if in.ProfileID < 0 {
		return time.Time{}, "invalid profile_id"
	}
	if in.RecurringDay < 0 || in.RecurringDay > 31 {
		return time.Time{}, "recurring_day must be between 1 and 31"
	}
	if in.RecurringKind != "" && in.RecurringKind != recurringFixed && in.RecurringKind != recurringVariable {
		return time.Time{}, "recurring_kind must be fixed or variable"
	}
	if math.IsNaN(in.RecurringEstimate) || math.IsInf(in.RecurringEstimate, 0) || in.RecurringEstimate < 0 || in.RecurringEstimate >= 1e10 {
		return time.Time{}, "recurring_estimate must be a positive number"
	}
	in.RecurringEstimate = math.Round(in.RecurringEstimate*100) / 100
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
		if len([]rune(it.Name)) > 100 || math.IsNaN(it.Amount) || math.IsInf(it.Amount, 0) || it.Amount < 0 || it.Amount >= 1e10 ||
			it.CategoryID < 0 || it.SuggestedCategoryID < 0 {
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
SELECT e.id, e.merchant, e.amount, e.spent_at, e.category_id, c.name, e.note, e.items, e.profile_id, e.client_uid,
       COALESCE(e.recurring_day, 0), e.recurring_remind, e.recurring_kind, COALESCE(e.recurring_estimate, 0),
       ARRAY(SELECT i.id FROM expense.receipt_images i WHERE i.expense_id = e.id ORDER BY i.position, i.id)
FROM expense.expenses e JOIN expense.categories c ON c.id = e.category_id `

type scanner interface{ Scan(dest ...any) error }

func scanExpense(s scanner) (expenseOut, error) {
	var e expenseOut
	var d time.Time
	var items []byte
	var imageIDs pq.Int64Array
	err := s.Scan(&e.ID, &e.Merchant, &e.Amount, &d, &e.CategoryID, &e.CategoryName, &e.Note, &items, &e.ProfileID, &e.ClientUID, &e.RecurringDay, &e.RecurringRemind, &e.RecurringKind, &e.RecurringEstimate, &imageIDs)
	e.Date = d.Format(dateLayout)
	e.Items = []expenseItem{}
	e.ImageIDs = []int64{} // JSON'da null degil []
	if len(imageIDs) > 0 {
		e.ImageIDs = []int64(imageIDs)
	}
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
	if !h.itemCategoriesOK(c, in.Items) {
		return
	}
	userID := c.GetInt64("userID")
	profileID, found, err := h.resolveProfile(userID, in.ProfileID)
	if err != nil {
		serverError(c)
		return
	}
	if !found {
		c.JSON(http.StatusNotFound, gin.H{"error": "profile not found"})
		return
	}
	uid := in.ClientUID
	if uid == "" {
		uid = newUID()
	}
	itemsJSON, _ := json.Marshal(itemsForStorage(in.Items))
	tx, err := h.db.Begin()
	if err != nil {
		serverError(c)
		return
	}
	defer tx.Rollback()
	id, created, err := insertExpense(tx, userID, profileID, uid, in, d, string(itemsJSON))
	if isFKViolation(err) {
		badRequest(c, "unknown category_id")
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	if created {
		if err := saveRules(tx, userID, collectRuleUpdates(in)); err != nil {
			serverError(c)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		serverError(c)
		return
	}
	status := http.StatusCreated
	if !created {
		status = http.StatusOK // ayni client_uid daha once kaydedilmis (idempotent tekrar)
	}
	h.respondExpense(c, status, id)
}

// insertExpense fisi ekler; (user_id, client_uid) zaten varsa mevcut kaydin id'sini ve created=false doner.
func insertExpense(q interface {
	QueryRow(query string, args ...any) *sql.Row
}, userID, profileID int64, uid string, in expenseInput, d time.Time, itemsJSON string) (int64, bool, error) {
	var id int64
	err := q.QueryRow(
		`INSERT INTO expense.expenses (user_id, profile_id, client_uid, merchant, amount, spent_at, category_id, note, items, recurring_day, recurring_remind, recurring_kind, recurring_estimate)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
		 ON CONFLICT (user_id, client_uid) DO NOTHING RETURNING id`,
		userID, profileID, uid, in.Merchant, in.Amount, d, in.CategoryID, in.Note, itemsJSON, in.recurringArg(), in.remind(), in.kind(), in.estimateArg()).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		err = q.QueryRow(`SELECT id FROM expense.expenses WHERE user_id = $1 AND client_uid = $2`, userID, uid).Scan(&id)
		return id, false, err
	}
	return id, err == nil, err
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
	one := []expenseOut{e}
	if h.fillItemCategories(one) != nil {
		serverError(c)
		return
	}
	c.JSON(status, one[0])
}

// itemCategoriesOK kalem kategori id'lerini dogrular; gecersizse 400 yazar ve false doner.
func (h *handler) itemCategoriesOK(c *gin.Context, items []expenseItem) bool {
	cats, err := h.loadCategories()
	if err != nil {
		serverError(c)
		return false
	}
	if !itemCategoriesValid(items, cats) {
		badRequest(c, "unknown category_id")
		return false
	}
	return true
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
	if v := c.Query("profile_id"); v != "" {
		pid, ok := h.profileFilter(c, v)
		if !ok {
			return
		}
		args = append(args, pid)
		q += ` AND e.profile_id = $` + strconv.Itoa(len(args))
	}
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
	if rows.Err() != nil || h.fillItemCategories(out) != nil {
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
	if !h.itemCategoriesOK(c, in.Items) {
		return
	}
	// profile_id verilmisse fis o profile tasinir (profil hesaba ait olmali); verilmemisse profil korunur.
	var moveTo any
	if in.ProfileID != 0 {
		pid, found, err := h.resolveProfile(c.GetInt64("userID"), in.ProfileID)
		if err != nil {
			serverError(c)
			return
		}
		if !found {
			c.JSON(http.StatusNotFound, gin.H{"error": "profile not found"})
			return
		}
		moveTo = pid
	}
	itemsJSON, _ := json.Marshal(itemsForStorage(in.Items))
	tx, err := h.db.Begin()
	if err != nil {
		serverError(c)
		return
	}
	defer tx.Rollback()
	res, err := tx.Exec(
		`UPDATE expense.expenses SET merchant=$1, amount=$2, spent_at=$3, category_id=$4, note=$5, items=$6,
		 profile_id = COALESCE($9::bigint, profile_id), recurring_day = $10, recurring_remind = $11, recurring_kind = $12, recurring_estimate = $13
		 WHERE id=$7 AND user_id=$8`,
		in.Merchant, in.Amount, d, in.CategoryID, in.Note, string(itemsJSON), id, c.GetInt64("userID"), moveTo,
		in.recurringArg(), in.remind(), in.kind(), in.estimateArg())
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
	if err := saveRules(tx, c.GetInt64("userID"), collectRuleUpdates(in)); err != nil || tx.Commit() != nil {
		serverError(c)
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

	sq := `SELECT c.id, c.name, SUM(e.amount), COUNT(*)
		 FROM expense.expenses e JOIN expense.categories c ON c.id = e.category_id
		 WHERE e.user_id = $1 AND e.spent_at BETWEEN $2 AND $3`
	sargs := []any{c.GetInt64("userID"), from, to}
	if v := c.Query("profile_id"); v != "" {
		pid, ok := h.profileFilter(c, v)
		if !ok {
			return
		}
		sargs = append(sargs, pid)
		sq += ` AND e.profile_id = $4`
	}
	rows, err := h.db.Query(sq+` GROUP BY c.id, c.name ORDER BY SUM(e.amount) DESC`, sargs...)
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

// profileFilter profile_id sorgu parametresini dogrular (sahiplik); gecersiz/yabanci profil -> 400/404 yazar.
func (h *handler) profileFilter(c *gin.Context, v string) (int64, bool) {
	id, err := strconv.ParseInt(v, 10, 64)
	if err != nil || id <= 0 {
		badRequest(c, "invalid profile_id")
		return 0, false
	}
	pid, found, err := h.resolveProfile(c.GetInt64("userID"), id)
	if err != nil {
		serverError(c)
		return 0, false
	}
	if !found {
		c.JSON(http.StatusNotFound, gin.H{"error": "profile not found"})
		return 0, false
	}
	return pid, true
}
