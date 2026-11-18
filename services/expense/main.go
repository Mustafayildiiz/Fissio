package main

import (
	"database/sql"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	_ "github.com/lib/pq"
)

func main() {
	db, err := sql.Open("postgres", os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	waitForDB(db)
	if err := migrate(db); err != nil {
		log.Fatalf("migration failed: %v", err)
	}

	// Access token'i auth servisi imzalar: JWT_ACCESS_SECRET (yoksa eski JWT_SECRET) iki serviste ayni olmali.
	secret := os.Getenv("JWT_ACCESS_SECRET")
	if secret == "" {
		secret = os.Getenv("JWT_SECRET")
	}
	if secret == "" {
		log.Fatal("JWT_ACCESS_SECRET (or JWT_SECRET) is required")
	}

	h := &handler{db: db, ocrFactory: NewOcrEngineFactoryFromEnv()}
	// Iptal edilen oturum (cikis, uzaktan cikis, hesap silme) en gec 10 sn icinde reddedilir.
	sessions := newSessionChecker(db, 10*time.Second)
	r := buildRouter(h, []byte(secret), sessions.alive)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Fatal(r.Run(":" + port))
}

// buildRouter tum rotalari kurar (testler de gercek rota tablosunu kullanir). alive nil ise oturum kontrolu yapilmaz.
func buildRouter(h *handler, secret []byte, alive func(sid string) (bool, error)) *gin.Engine {
	r := gin.Default()
	r.Use(cors())

	r.GET("/health", func(c *gin.Context) {
		if err := h.db.Ping(); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"service": "expense", "status": "db_down"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"service": "expense", "status": "ok", "time": time.Now().UTC()})
	})

	api := r.Group("/", authMiddleware(secret, alive))
	api.GET("/profiles", h.listProfiles)
	api.POST("/profiles", h.createProfile)
	api.PUT("/profiles/:id", h.renameProfile)
	api.DELETE("/profiles/:id", h.deleteProfile)
	api.PUT("/profiles/:id/avatar", h.putAvatar)
	api.GET("/profiles/:id/avatar", h.getAvatar)
	api.DELETE("/profiles/:id/avatar", h.deleteAvatar)
	api.GET("/categories", h.listCategories)
	api.POST("/receipts/parse", h.parseReceipt)
	api.POST("/receipts/scan", h.scanReceipt)
	api.POST("/expenses", h.createExpense)
	api.POST("/expenses/bulk", h.bulkExpenses)
	api.GET("/expenses", h.listExpenses)
	api.GET("/expenses/:id", h.getExpense)
	api.PUT("/expenses/:id", h.updateExpense)
	api.DELETE("/expenses/:id", h.deleteExpense)
	api.POST("/expenses/:id/images", h.uploadImages)
	api.GET("/expenses/:id/images/:imageId", h.getImage)
	api.DELETE("/expenses/:id/images/:imageId", h.deleteImage)
	api.GET("/reports/summary", h.summary)
	api.GET("/budgets", h.listBudgets)
	api.PUT("/budgets", h.putBudget)
	api.DELETE("/budgets/:id", h.deleteBudget)
	api.GET("/recurring", h.listRecurring)
	api.GET("/category-rules", h.listRules)
	api.DELETE("/category-rules/:id", h.deleteRule)
	return r
}

func waitForDB(db *sql.DB) {
	for i := 0; i < 30; i++ {
		if err := db.Ping(); err == nil {
			return
		}
		time.Sleep(time.Second)
	}
	log.Fatal("database not reachable")
}

// cors: gelistirme icin tum kokenlere izin verir (web istemcisi). Yayinda kisitlanmali.
func cors() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-OCR-Engine")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}
