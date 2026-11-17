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
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	db, err := sql.Open("postgres", os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	waitForDB(db)
	if err := migrate(db); err != nil {
		log.Fatalf("migration failed: %v", err)
	}

	dummy, err := bcrypt.GenerateFromPassword([]byte("dummy-password"), bcrypt.DefaultCost)
	if err != nil {
		log.Fatal(err)
	}

	h := &handler{db: db, cfg: cfg, mailer: newMailer(cfg.smtp), dummyHash: dummy}
	r := buildRouter(h)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Fatal(r.Run(":" + port))
}

func buildRouter(h *handler) *gin.Engine {
	r := gin.Default()
	// Istemci IP'si dogrudan baglantidan alinir: sahte X-Forwarded-For sinirlari asamaz ve sessions.ip'ye yazilmaz.
	_ = r.SetTrustedProxies(nil)
	r.Use(cors())

	r.GET("/health", func(c *gin.Context) {
		if err := h.db.Ping(); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"service": "auth", "status": "db_down"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"service": "auth", "status": "ok", "time": time.Now().UTC()})
	})

	// IP basina dakikalik sinirlar (brute-force / e-posta spam korumasi). Her rota kendi sayacini kullanir;
	// boylece normal bir akis (kayit, dogrulama, giris, silme...) birbirinin kotasini tuketmez.
	lim := func(n int) gin.HandlerFunc {
		if h.rateMax > 0 {
			n = h.rateMax // testlerde yukseltilir
		}
		return newIPLimiter(n, time.Minute).middleware()
	}
	authed := authMiddleware(h.cfg.accessSecret, h.sessionAlive)

	g := r.Group("/auth")
	g.POST("/register", lim(20), h.register)
	g.POST("/verify-email", lim(30), h.verifyEmail)
	g.POST("/resend-code", lim(10), h.resendCode)
	g.POST("/login", lim(30), h.login)
	g.POST("/refresh", h.refresh)
	g.POST("/logout", h.logout)
	g.POST("/forgot-password", lim(10), h.forgotPassword)
	g.POST("/reset-password", lim(20), h.resetPassword)
	g.GET("/me", authed, h.me)
	g.GET("/sessions", authed, h.listSessions)
	g.DELETE("/sessions/:id", authed, h.revokeSession)
	g.POST("/logout-all", authed, h.logoutAll)
	g.DELETE("/account", authed, lim(10), h.deleteAccount) // token + sifre gerekir; sifre denemesi yine sinirli
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

// migrate semayi idempotent olarak olusturur/gunceller (versiyonlu migration araci yok).
func migrate(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (
	id            BIGSERIAL PRIMARY KEY,
	email         TEXT NOT NULL UNIQUE,
	password_hash TEXT NOT NULL,
	created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);`); err != nil {
		return err
	}

	// email_verified_at ilk kez ekleniyorsa mevcut kullanicilar dogrulanmis sayilir (geriye uyumluluk).
	var hasVerified bool
	if err := tx.QueryRow(`SELECT EXISTS (SELECT 1 FROM information_schema.columns
		WHERE table_schema='auth' AND table_name='users' AND column_name='email_verified_at')`).Scan(&hasVerified); err != nil {
		return err
	}
	if !hasVerified {
		if _, err := tx.Exec(`
ALTER TABLE auth.users ADD COLUMN email_verified_at TIMESTAMPTZ;
UPDATE auth.users SET email_verified_at = created_at;`); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS name TEXT NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS auth.email_otps (
	id           BIGSERIAL PRIMARY KEY,
	email        TEXT NOT NULL,
	purpose      TEXT NOT NULL CHECK (purpose IN ('verify','reset')),
	code_hash    TEXT NOT NULL,
	expires_at   TIMESTAMPTZ NOT NULL,
	attempts     INT NOT NULL DEFAULT 0,
	consumed_at  TIMESTAMPTZ,
	last_sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
	created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_email_otps_lookup ON auth.email_otps (email, purpose, id DESC);

CREATE TABLE IF NOT EXISTS auth.sessions (
	id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
	user_id        BIGINT NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
	device_name    TEXT NOT NULL DEFAULT '',
	platform       TEXT NOT NULL DEFAULT '',
	ip             TEXT NOT NULL DEFAULT '',
	created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
	last_active_at TIMESTAMPTZ NOT NULL DEFAULT now(),
	revoked_at     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON auth.sessions (user_id) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS auth.refresh_tokens (
	id         BIGSERIAL PRIMARY KEY,
	session_id UUID NOT NULL REFERENCES auth.sessions(id) ON DELETE CASCADE,
	token_hash TEXT NOT NULL UNIQUE,
	expires_at TIMESTAMPTZ NOT NULL,
	used_at    TIMESTAMPTZ,
	created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_refresh_session ON auth.refresh_tokens (session_id);`); err != nil {
		return err
	}
	return tx.Commit()
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
