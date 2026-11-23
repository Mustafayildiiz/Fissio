package main

import (
	"database/sql"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	_ "github.com/lib/pq"

	"fissio/expense/internal/scan"
)

func main() {
	db, err := sql.Open("postgres", os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	// Havuz siniri: tek serviste kontrolsuz baglanti birikmesi Postgres'in max_connections'ini (varsayilan 100) tuketmesin.
	db.SetMaxOpenConns(envInt("DB_MAX_OPEN_CONNS", 25))
	db.SetMaxIdleConns(envInt("DB_MAX_IDLE_CONNS", 5))
	db.SetConnMaxLifetime(30 * time.Minute)

	waitForDB(db)
	if err := migrate(db); err != nil {
		log.Fatalf("migration failed: %v", err)
	}

	if err := checkProductionSecrets(os.Getenv); err != nil {
		log.Fatal(err)
	}
	// Access token'i auth servisi imzalar: HS256 (JWT_ACCESS_SECRET/JWT_SECRET iki serviste ayni) ya da EdDSA
	// (JWT_ED25519_PUBLIC_KEY: yalniz genel anahtar; bkz. accesskeys.go).
	verifier, err := loadAccessVerifier()
	if err != nil {
		log.Fatal(err)
	}

	// Servisler arasi iletisim: auth'un ic API'si (oturum dogrulama) ve bu servisin ic API'si (hesap verisi silme).
	internalToken := os.Getenv("INTERNAL_TOKEN")
	if internalToken == "" {
		log.Fatal("INTERNAL_TOKEN is required")
	}
	authURL := os.Getenv("AUTH_INTERNAL_URL")
	if authURL == "" {
		authURL = "http://auth:9090"
	}

	h := &handler{db: db, ocrFactory: scan.NewOcrEngineFactoryFromEnv(), inbound: inboundConfigFromEnv()}
	// Basarisiz e-posta aktarimi bildirimi: auth (kullanicinin e-postasinin sahibi) gonderir; kuyruk + tek worker.
	h.notifier = newAuthFailureNotifier(authURL, internalToken, failureNoticeQueue)
	// Iptal edilen oturum (cikis, uzaktan cikis, hesap silme) en gec 10 sn icinde reddedilir.
	sessions := newSessionChecker(authURL, internalToken, 10*time.Second)
	r := buildRouterWith(h, verifier, sessions.alive)

	// Ic API ayri portta (host'a yayinlanmaz); bkz. internal.go.
	internalPort := os.Getenv("INTERNAL_PORT")
	if internalPort == "" {
		internalPort = "9090"
	}
	go func() {
		isrv := &http.Server{
			Addr:              ":" + internalPort,
			Handler:           buildInternalRouter(h, internalToken),
			ReadHeaderTimeout: 10 * time.Second,
			ReadTimeout:       30 * time.Second,
			WriteTimeout:      2 * time.Minute, // hesap verisi silme (buyuk hesaplar) uzun surebilir
			IdleTimeout:       60 * time.Second,
		}
		log.Fatal(isrv.ListenAndServe())
	}()

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	// Zaman asimlari: yavas/askida istemci (slowloris) baglanti tutamaz. WriteTimeout govde okumayi da kapsar:
	// 6 sayfa yukleme + en fazla scanTotalTimeout OCR + ayristirma icin genis tutulur.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       2 * time.Minute,
		WriteTimeout:      4 * time.Minute,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	log.Fatal(srv.ListenAndServe())
}

// buildRouter tum rotalari kurar (testler de gercek rota tablosunu kullanir). alive nil ise oturum kontrolu yapilmaz.
func buildRouter(h *handler, secret []byte, alive func(sid string, userID int64) (bool, error)) *gin.Engine {
	return buildRouterWith(h, hmacVerifier(secret), alive)
}

// buildRouterWith buildRouter'in dogrulayici (HS256/EdDSA) alan halidir.
func buildRouterWith(h *handler, v accessVerifier, alive func(sid string, userID int64) (bool, error)) *gin.Engine {
	r := gin.Default()
	r.Use(corsFor(os.Getenv("CORS_ALLOWED_ORIGINS"), os.Getenv("APP_ENV")))

	r.GET("/health", func(c *gin.Context) {
		if err := h.db.Ping(); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"service": "expense", "status": "db_down"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"service": "expense", "status": "ok", "time": time.Now().UTC()})
	})

	// Harici posta yonlendiricisinin webhook'u: JWT yok, X-Webhook-Secret ile korunur (bkz. inbound.go).
	r.POST("/webhooks/inbound-email", h.inboundEmail)

	api := r.Group("/", authMiddlewareWith(v, alive))
	api.GET("/inbound-address", h.getInboundAddress)
	api.PUT("/inbound-address", h.putInboundAddress)
	api.POST("/inbound-address/rotate", h.rotateInboundAddress)
	api.POST("/inbound-address/pause", h.pauseInboundAddress)
	api.POST("/inbound-address/resume", h.resumeInboundAddress)
	api.GET("/inbound-address/confirmation", h.getForwardingConfirmation)
	api.GET("/inbound-address/history", h.getInboundHistory)
	api.GET("/inbound-settings", h.getInboundSettings)
	api.PUT("/inbound-settings", h.putInboundSettings)
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
	api.GET("/expenses/ids", h.listExpenseIDs) // /expenses/:id'den ONCE: sabit yol parametreye yakalanmasin
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
