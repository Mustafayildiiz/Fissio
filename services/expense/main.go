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

	secret := os.Getenv("JWT_SECRET")
	if secret == "" {
		log.Fatal("JWT_SECRET is required")
	}

	r := gin.Default()
	r.Use(cors())

	r.GET("/health", func(c *gin.Context) {
		if err := db.Ping(); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"service": "expense", "status": "db_down"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"service": "expense", "status": "ok", "time": time.Now().UTC()})
	})

	h := &handler{db: db}
	api := r.Group("/", authMiddleware([]byte(secret)))
	api.GET("/categories", h.listCategories)
	api.POST("/receipts/parse", h.parseReceipt)
	api.POST("/expenses", h.createExpense)
	api.GET("/expenses", h.listExpenses)
	api.GET("/expenses/:id", h.getExpense)
	api.PUT("/expenses/:id", h.updateExpense)
	api.DELETE("/expenses/:id", h.deleteExpense)
	api.GET("/reports/summary", h.summary)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Fatal(r.Run(":" + port))
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
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}
