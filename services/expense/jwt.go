package main

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"github.com/lib/pq"
)

// accessClaims auth servisinin urettigi kisa omurlu access token'dir (auth/jwt.go ile ayni bicim).
// sid = auth.sessions.id; iptal edilmis oturumun token'i sureci dolmadan reddedilir.
type accessClaims struct {
	SID string `json:"sid"`
	Typ string `json:"typ"`
	jwt.RegisteredClaims
}

// errAuthUnavailable auth.sessions henuz yok (auth servisi migrate etmedi) veya okunamiyor.
var errAuthUnavailable = errors.New("auth sessions unavailable")

// sessionChecker oturumun iptal edilmedigini ayni Postgres'teki auth.sessions'tan dogrular.
// Sonuc kisa sure (ttl) onbelleklenir; ttl=0 onbellegi kapatir (testler).
type sessionChecker struct {
	db  *sql.DB
	ttl time.Duration

	mu    sync.Mutex
	cache map[string]cachedSession
}

type cachedSession struct {
	ok    bool
	until time.Time
}

func newSessionChecker(db *sql.DB, ttl time.Duration) *sessionChecker {
	return &sessionChecker{db: db, ttl: ttl, cache: map[string]cachedSession{}}
}

func (s *sessionChecker) alive(sid string) (bool, error) {
	if s.ttl > 0 {
		s.mu.Lock()
		if v, ok := s.cache[sid]; ok && time.Now().Before(v.until) {
			s.mu.Unlock()
			return v.ok, nil
		}
		s.mu.Unlock()
	}
	var ok bool
	err := s.db.QueryRow(
		`SELECT EXISTS (SELECT 1 FROM auth.sessions WHERE id = $1::uuid AND revoked_at IS NULL)`, sid).Scan(&ok)
	if err != nil {
		var pqErr *pq.Error
		// 42P01 undefined_table / 3F000 invalid_schema_name: auth servisi henuz sema olusturmadi.
		if errors.As(err, &pqErr) && (pqErr.Code == "42P01" || pqErr.Code == "3F000") {
			return false, errAuthUnavailable
		}
		return false, err
	}
	if s.ttl > 0 {
		s.mu.Lock()
		if len(s.cache) > 5000 {
			s.cache = map[string]cachedSession{}
		}
		s.cache[sid] = cachedSession{ok: ok, until: time.Now().Add(s.ttl)}
		s.mu.Unlock()
	}
	return ok, nil
}

// authMiddleware Bearer access token dogrular ve "userID" / "sid" degerlerini context'e koyar (FR-1.4).
// alive nil degilse oturumun iptal edilmedigi de kontrol edilir.
func authMiddleware(secret []byte, alive func(sid string) (bool, error)) gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.GetHeader("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing bearer token", "code": "unauthorized"})
			return
		}
		claims := &accessClaims{}
		tok, err := jwt.ParseWithClaims(strings.TrimPrefix(h, "Bearer "), claims,
			func(t *jwt.Token) (any, error) { return secret, nil },
			jwt.WithValidMethods([]string{"HS256"}))
		if err != nil || !tok.Valid || claims.Typ != "access" || claims.SID == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid or expired token", "code": "unauthorized"})
			return
		}
		id, err := strconv.ParseInt(claims.Subject, 10, 64)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid token subject", "code": "unauthorized"})
			return
		}
		if alive != nil {
			ok, err := alive(claims.SID)
			switch {
			case errors.Is(err, errAuthUnavailable):
				c.Header("Retry-After", "5")
				c.AbortWithStatusJSON(http.StatusServiceUnavailable, gin.H{"error": "auth unavailable, retry shortly", "code": "auth_unavailable"})
				return
			case err != nil:
				c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
				return
			case !ok:
				c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "session revoked", "code": "session_revoked"})
				return
			}
		}
		c.Set("userID", id)
		c.Set("sid", claims.SID)
		c.Next()
	}
}
