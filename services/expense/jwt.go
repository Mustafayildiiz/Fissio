package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

// accessClaims auth servisinin urettigi kisa omurlu access token'dir (auth/jwt.go ile ayni bicim).
// sid = auth.sessions.id; iptal edilmis oturumun token'i sureci dolmadan reddedilir.
type accessClaims struct {
	SID string `json:"sid"`
	Typ string `json:"typ"`
	jwt.RegisteredClaims
}

// errAuthUnavailable auth servisine ulasilamiyor (henuz acilmadi, ag hatasi, 5xx) veya yaniti anlasilamiyor.
var errAuthUnavailable = errors.New("auth sessions unavailable")

// sessionChecker oturumun iptal edilmedigini auth servisinin ic (internal) API'sinden dogrular:
// GET {AUTH_INTERNAL_URL}/internal/sessions/:sid. Auth semasina dogrudan SQL ATILMAZ. Sonuc kisa sure (ttl)
// onbelleklenir; ttl=0 onbellegi kapatir (testler).
type sessionChecker struct {
	baseURL string
	token   string
	client  *http.Client
	ttl     time.Duration

	mu    sync.Mutex
	cache map[string]cachedSession
}

type cachedSession struct {
	ok    bool
	until time.Time
}

func newSessionChecker(baseURL, token string, ttl time.Duration) *sessionChecker {
	return &sessionChecker{
		baseURL: strings.TrimRight(baseURL, "/"),
		token:   token,
		client:  &http.Client{Timeout: 3 * time.Second},
		ttl:     ttl,
		cache:   map[string]cachedSession{},
	}
}

// sessionInfo auth'un GET /internal/sessions/:sid yaniti.
type sessionInfo struct {
	Alive  bool  `json:"alive"`
	UserID int64 `json:"user_id"`
}

// alive oturumun (sid) hala acik VE token'daki kullaniciya (userID) ait oldugunu dogrular.
func (s *sessionChecker) alive(sid string, userID int64) (bool, error) {
	key := sid + "|" + strconv.FormatInt(userID, 10)
	if s.ttl > 0 {
		s.mu.Lock()
		if v, ok := s.cache[key]; ok && time.Now().Before(v.until) {
			s.mu.Unlock()
			return v.ok, nil
		}
		s.mu.Unlock()
	}
	req, err := http.NewRequest(http.MethodGet, s.baseURL+"/internal/sessions/"+url.PathEscape(sid), nil)
	if err != nil {
		return false, errAuthUnavailable
	}
	req.Header.Set(internalTokenHeader, s.token)
	resp, err := s.client.Do(req)
	if err != nil {
		return false, errAuthUnavailable
	}
	defer resp.Body.Close()
	var ok bool
	switch {
	case resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusBadRequest:
		ok = false // bilinmeyen / bicimi bozuk oturum
	case resp.StatusCode == http.StatusOK:
		var info sessionInfo
		if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&info); err != nil {
			return false, errAuthUnavailable
		}
		ok = info.Alive && info.UserID == userID
	default:
		// 401 (yanlis INTERNAL_TOKEN), 5xx...: oturum "iptal" degil, dogrulama yapilamiyor.
		return false, errAuthUnavailable
	}
	if s.ttl > 0 {
		s.mu.Lock()
		if len(s.cache) > 5000 {
			s.cache = map[string]cachedSession{}
		}
		s.cache[key] = cachedSession{ok: ok, until: time.Now().Add(s.ttl)}
		s.mu.Unlock()
	}
	return ok, nil
}

// authMiddleware Bearer access token dogrular ve "userID" / "sid" degerlerini context'e koyar (FR-1.4).
// alive nil degilse oturumun iptal edilmedigi de kontrol edilir.
func authMiddleware(secret []byte, alive func(sid string, userID int64) (bool, error)) gin.HandlerFunc {
	return authMiddlewareWith(hmacVerifier(secret), alive)
}

// authMiddlewareWith authMiddleware'in dogrulayici (HS256 ya da EdDSA) alan halidir.
func authMiddlewareWith(v accessVerifier, alive func(sid string, userID int64) (bool, error)) gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.GetHeader("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing bearer token", "code": "unauthorized"})
			return
		}
		claims := &accessClaims{}
		tok, err := jwt.ParseWithClaims(strings.TrimPrefix(h, "Bearer "), claims,
			v.keyfunc,
			jwt.WithValidMethods([]string{v.method()}))
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
			ok, err := alive(claims.SID, id)
			switch {
			case errors.Is(err, errAuthUnavailable):
				c.Header("Retry-After", "5")
				c.AbortWithStatusJSON(http.StatusServiceUnavailable, gin.H{"error": "auth unavailable, retry shortly", "code": "auth_unavailable"})
				return
			case err != nil:
				c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"error": "internal error", "code": "internal"})
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
