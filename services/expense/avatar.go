package main

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
)

// Profil avatari: profile (dolayisiyla hesaba) bagli tek gorsel. Yalnizca sahibinin JWT'siyle
// okunur/yazilir; baska hesabin profili 404 doner. Profil silinince satirla birlikte gider.
const maxAvatarBytes = 1 << 20 // istemci zaten ~512px'e kucultur; 1 MB ust sinir

func parseProfileID(c *gin.Context) (int64, bool) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		badRequest(c, "invalid id")
		return 0, false
	}
	return id, true
}

func (h *handler) putAvatar(c *gin.Context) {
	id, ok := parseProfileID(c)
	if !ok {
		return
	}
	userID := c.GetInt64("userID")
	// Sahiplik ONCE: baskasinin profiline gorsel yazilamaz.
	pid, found, err := h.resolveProfile(userID, id)
	if err != nil {
		serverError(c)
		return
	}
	if !found {
		c.JSON(http.StatusNotFound, gin.H{"error": "profile not found"})
		return
	}
	files, ok := limitBody(c)
	if !ok {
		return
	}
	if len(files) != 1 {
		badRequest(c, "multipart field 'file' is required")
		return
	}
	f := files[0]
	if f.Size == 0 {
		badRequest(c, "empty file")
		return
	}
	if f.Size > maxAvatarBytes {
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "avatar must be under 1MB"})
		return
	}
	data, err := readImage(f)
	if err != nil || len(data) == 0 || len(data) > maxAvatarBytes {
		badRequest(c, "invalid file")
		return
	}
	// Tur istemcinin bildirdigi degerden degil, icerikten sezilir.
	ctype := http.DetectContentType(data)
	if !allowedImageTypes[ctype] {
		badRequest(c, "only jpeg, png and webp images are allowed")
		return
	}
	var version int
	if err := h.db.QueryRow(
		`UPDATE expense.profiles SET avatar=$1, avatar_type=$2, avatar_version=avatar_version+1
		 WHERE id=$3 AND user_id=$4 RETURNING avatar_version`,
		data, ctype, pid, userID).Scan(&version); err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, gin.H{"avatar_version": version})
}

func (h *handler) getAvatar(c *gin.Context) {
	id, ok := parseProfileID(c)
	if !ok {
		return
	}
	var ctype sql.NullString
	var data []byte
	err := h.db.QueryRow(`SELECT avatar_type, avatar FROM expense.profiles WHERE id=$1 AND user_id=$2`,
		id, c.GetInt64("userID")).Scan(&ctype, &data)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && len(data) == 0) {
		c.JSON(http.StatusNotFound, gin.H{"error": "avatar not found"})
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	// ?v=<avatar_version> ile onbellek kirilir; bu yuzden uzun sureli onbellek guvenli.
	c.Header("Cache-Control", "private, max-age=3600")
	c.Header("X-Content-Type-Options", "nosniff")
	c.Data(http.StatusOK, ctype.String, data)
}

func (h *handler) deleteAvatar(c *gin.Context) {
	id, ok := parseProfileID(c)
	if !ok {
		return
	}
	var version int
	err := h.db.QueryRow(
		`UPDATE expense.profiles SET avatar=NULL, avatar_type=NULL,
		        avatar_version = CASE WHEN avatar IS NULL THEN avatar_version ELSE avatar_version+1 END
		 WHERE id=$1 AND user_id=$2 RETURNING 0`,
		id, c.GetInt64("userID")).Scan(&version)
	if errors.Is(err, sql.ErrNoRows) {
		c.JSON(http.StatusNotFound, gin.H{"error": "profile not found"})
		return
	}
	if err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, gin.H{"avatar_version": version})
}
