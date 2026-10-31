package main

import (
	"database/sql"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	_ "github.com/lib/pq"
	"golang.org/x/crypto/bcrypt"
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

	dummy, err := bcrypt.GenerateFromPassword([]byte("dummy-password"), bcrypt.DefaultCost)
	if err != nil {
		log.Fatal(err)
	}

	r := gin.Default()
	r.Use(cors())

	r.GET("/health", func(c *gin.Context) {
		if err := db.Ping(); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"service": "auth", "status": "db_down"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"service": "auth", "status": "ok", "time": time.Now().UTC()})
	})

	h := &handler{db: db, secret: []byte(secret), dummyHash: dummy}
	g := r.Group("/auth")
	g.POST("/register", h.register)
	g.POST("/login", h.login)
	g.GET("/me", authMiddleware(h.secret), h.me)

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

func migrate(db *sql.DB) error {
	_, err := db.Exec(`
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (
	id            BIGSERIAL PRIMARY KEY,
	email         TEXT NOT NULL UNIQUE,
	password_hash TEXT NOT NULL,
	created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);`)
	return err
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
