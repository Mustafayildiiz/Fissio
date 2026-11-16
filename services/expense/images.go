package main

import (
	"database/sql"
	"errors"
	"io"
	"mime/multipart"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
)

// Fis fotograflari: hesaba bagli, yalnizca sahibinin JWT'siyle erisilir, fis silinince silinir
// (ON DELETE CASCADE). OCR servisi hicbir sey saklamaz.
const (
	maxImageBytes   = 5 << 20  // fotograf basina
	maxRequestBytes = 30 << 20 // istek toplami (tarama ve yukleme)
	maxScanPages    = 6        // tek taramada en fazla sayfa
	maxStoredImages = 10       // fis basina saklanan en fazla fotograf
)

var allowedImageTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/webp": true}

// limitBody istek govdesini maxRequestBytes ile sinirlar ve multipart formunu okur.
// Sinir asilirsa 413, bozuk govdede 400 yazar ve false doner.
func limitBody(c *gin.Context) (files []*multipart.FileHeader, ok bool) {
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxRequestBytes)
	form, err := c.MultipartForm()
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "request too large"})
		} else {
			badRequest(c, "multipart field 'file' is required")
		}
		return nil, false
	}
	return form.File["file"], true
}

// readImage, multipart parcasini bellege okur (boyut siniri kontrol edilmis olmali).
func readImage(fh *multipart.FileHeader) ([]byte, error) {
	r, err := fh.Open()
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return io.ReadAll(io.LimitReader(r, maxImageBytes+1))
}

// ownsExpense, fisin giris yapan kullaniciya ait olup olmadigini soyler.
func (h *handler) ownsExpense(c *gin.Context, id int64) (bool, error) {
	var one int
	err := h.db.QueryRow(`SELECT 1 FROM expense.expenses WHERE id = $1 AND user_id = $2`, id, c.GetInt64("userID")).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (h *handler) uploadImages(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		badRequest(c, "invalid id")
		return
	}
	// Sahiplik ONCE kontrol edilir: baskasinin fis kimligine fotograf eklenemez.
	owns, err := h.ownsExpense(c, id)
	if err != nil {
		serverError(c)
		return
	}
	if !owns {
		c.JSON(http.StatusNotFound, gin.H{"error": "expense not found"})
		return
	}

	files, ok := limitBody(c)
	if !ok {
		return
	}
	if len(files) == 0 {
		badRequest(c, "multipart field 'file' is required")
		return
	}
	var existing int
	if err := h.db.QueryRow(`SELECT count(*) FROM expense.receipt_images WHERE expense_id = $1`, id).Scan(&existing); err != nil {
		serverError(c)
		return
	}
	if existing+len(files) > maxStoredImages {
		badRequest(c, "too many images (max 10 per receipt)")
		return
	}

	type upload struct {
		ctype string
		data  []byte
	}
	var ups []upload
	for _, f := range files {
		if f.Size == 0 {
			badRequest(c, "empty file")
			return
		}
		if f.Size > maxImageBytes {
			c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "each image must be under 5MB"})
			return
		}
		data, err := readImage(f)
		if err != nil || len(data) == 0 {
			badRequest(c, "invalid file")
			return
		}
		// Tur istemcinin bildirdigi degerden degil, icerikten sezilir.
		ctype := http.DetectContentType(data)
		if !allowedImageTypes[ctype] {
			badRequest(c, "only jpeg, png and webp images are allowed")
			return
		}
		ups = append(ups, upload{ctype, data})
	}

	tx, err := h.db.Begin()
	if err != nil {
		serverError(c)
		return
	}
	defer tx.Rollback()
	var pos int
	if err := tx.QueryRow(`SELECT COALESCE(MAX(position), -1) + 1 FROM expense.receipt_images WHERE expense_id = $1`, id).Scan(&pos); err != nil {
		serverError(c)
		return
	}
	ids := []int64{}
	for _, u := range ups {
		var imgID int64
		if err := tx.QueryRow(
			`INSERT INTO expense.receipt_images (expense_id, user_id, position, content_type, data)
			 VALUES ($1,$2,$3,$4,$5) RETURNING id`,
			id, c.GetInt64("userID"), pos, u.ctype, u.data).Scan(&imgID); err != nil {
			serverError(c)
			return
		}
		ids = append(ids, imgID)
		pos++
	}
	if err := tx.Commit(); err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusCreated, gin.H{"image_ids": ids})
}

func (h *handler) getImage(c *gin.Context) {
	id, err1 := strconv.ParseInt(c.Param("id"), 10, 64)
	imgID, err2 := strconv.ParseInt(c.Param("imageId"), 10, 64)
	if err1 != nil || err2 != nil {
		badRequest(c, "invalid id")
		return
	}
	var ctype string
	var data []byte
	// Sahiplik receipt_images.user_id'ye degil, fisin sahibine (JOIN) gore dogrulanir.
	err := h.db.QueryRow(
		`SELECT i.content_type, i.data
		 FROM expense.receipt_images i JOIN expense.expenses e ON e.id = i.expense_id
		 WHERE i.id = $1 AND i.expense_id = $2 AND e.user_id = $3`,
		imgID, id, c.GetInt64("userID")).Scan(&ctype, &data)
	if errors.Is(err, sql.ErrNoRows) {
		c.JSON(http.StatusNotFound, gin.H{"error": "image not found"})
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	c.Header("Cache-Control", "private, max-age=3600")
	c.Header("X-Content-Type-Options", "nosniff")
	c.Data(http.StatusOK, ctype, data)
}

func (h *handler) deleteImage(c *gin.Context) {
	id, err1 := strconv.ParseInt(c.Param("id"), 10, 64)
	imgID, err2 := strconv.ParseInt(c.Param("imageId"), 10, 64)
	if err1 != nil || err2 != nil {
		badRequest(c, "invalid id")
		return
	}
	res, err := h.db.Exec(
		`DELETE FROM expense.receipt_images i USING expense.expenses e
		 WHERE i.id = $1 AND i.expense_id = $2 AND e.id = i.expense_id AND e.user_id = $3`,
		imgID, id, c.GetInt64("userID"))
	if err != nil {
		serverError(c)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "image not found"})
		return
	}
	c.Status(http.StatusNoContent)
}
