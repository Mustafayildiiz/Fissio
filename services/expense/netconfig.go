package main

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// corsFor CORS_ALLOWED_ORIGINS'e gore CORS ara katmanini kurar (auth/netconfig.go ile ayni sozlesme). Mobil istemci
// CORS'a ihtiyac duymaz:
//   - deger doluysa ("*" ya da virgullu kaynak listesi) yalnizca eslesen Origin icin baslik yazilir;
//   - bos ve APP_ENV=production: hic CORS basligi yok;
//   - bos ve gelistirme: "*" (Flutter web / yerel arac gelistirmesi icin).
func corsFor(allowed, appEnv string) gin.HandlerFunc {
	allowed = strings.TrimSpace(allowed)
	if allowed == "" && strings.ToLower(strings.TrimSpace(appEnv)) != "production" {
		allowed = "*"
	}
	origins := map[string]bool{}
	for _, o := range strings.Split(allowed, ",") {
		if o = strings.TrimSpace(o); o != "" {
			origins[o] = true
		}
	}
	return func(c *gin.Context) {
		origin := c.GetHeader("Origin")
		switch {
		case origins["*"]:
			c.Header("Access-Control-Allow-Origin", "*")
		case origin != "" && origins[origin]:
			c.Header("Access-Control-Allow-Origin", origin)
			c.Header("Vary", "Origin")
		default:
			c.Next()
			return
		}
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-OCR-Engine")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}
