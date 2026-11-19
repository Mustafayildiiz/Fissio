package main

import (
	"crypto/subtle"
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
)

// internalTokenHeader servisler arasi cagrilarin paylasilan gizli anahtari (INTERNAL_TOKEN).
const internalTokenHeader = "X-Internal-Token"

// userOwnedTables expense semasinda `user_id` tasiyan TUM tablolar; hesap silinirken bu siraya gore
// (cocuktan ebeveyne) temizlenir. Yeni bir `user_id`'li tablo eklendiginde buraya da eklenmelidir:
// TestPGUserOwnedTablesAreAllPurged bunu information_schema ile dogrular. Auth servisi artik expense
// semasina dokunmaz; bu liste yalnizca expense'e aittir.
var userOwnedTables = []string{
	"receipt_images",
	"expenses",
	"category_rules",
	"budgets",
	"profiles",
}

// purgeUser bir kullanicinin tum expense verisini tek islemde siler. Idempotenttir (veri yoksa da basarili).
func purgeUser(db *sql.DB, userID int64) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, table := range userOwnedTables {
		// Tablo adlari sabit listeden gelir (kullanici girdisi degil).
		if _, err := tx.Exec(fmt.Sprintf(`DELETE FROM expense.%s WHERE user_id = $1`, table), userID); err != nil {
			return fmt.Errorf("purge expense.%s: %w", table, err)
		}
	}
	return tx.Commit()
}

// internalAuth paylasilan INTERNAL_TOKEN'i sabit zamanli karsilastirir. Bos token tum istekleri reddeder.
func internalAuth(token string) gin.HandlerFunc {
	want := []byte(token)
	return func(c *gin.Context) {
		got := []byte(c.GetHeader(internalTokenHeader))
		if len(want) == 0 || subtle.ConstantTimeCompare(got, want) != 1 {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized", "code": "unauthorized"})
			return
		}
		c.Next()
	}
}

// buildInternalRouter servisler arasi (auth -> expense) rotalar. Ayri bir portta (INTERNAL_PORT, varsayilan
// 9090) dinlenir ve docker-compose'ta host'a YAYINLANMAZ; ek olarak INTERNAL_TOKEN ister.
func buildInternalRouter(h *handler, token string) *gin.Engine {
	r := gin.New()
	r.Use(gin.Recovery())
	r.GET("/health", func(c *gin.Context) { c.JSON(http.StatusOK, gin.H{"service": "expense-internal", "status": "ok"}) })
	in := r.Group("/internal", internalAuth(token))
	in.DELETE("/users/:id", h.internalPurgeUser)
	return r
}

// internalPurgeUser DELETE /internal/users/:id — auth hesap silerken cagirir; kullanicinin profilleri, fisleri,
// gorselleri, bütçe ve ogrenilmis kurallari kalici silinir.
func (h *handler) internalPurgeUser(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		badRequest(c, "invalid user id")
		return
	}
	if err := purgeUser(h.db, id); err != nil {
		log.Printf("internal purge user %d: %v", id, err)
		serverError(c)
		return
	}
	c.Status(http.StatusNoContent)
}
