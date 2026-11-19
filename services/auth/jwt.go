package main

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

// accessClaims: kisa omurlu access token. sid = auth.sessions.id (anlik iptal icin).
type accessClaims struct {
	SID string `json:"sid"`
	Typ string `json:"typ"`
	jwt.RegisteredClaims
}

func issueAccessToken(secret []byte, userID int64, sid string, ttl time.Duration) (string, time.Time, error) {
	return issueAccessTokenWith(jwt.SigningMethodHS256, secret, userID, sid, ttl)
}

// issueAccessTokenWith istenen yontemle (HS256 + gizli anahtar, ya da EdDSA + ozel anahtar) imzalar.
func issueAccessTokenWith(method jwt.SigningMethod, key any, userID int64, sid string, ttl time.Duration) (string, time.Time, error) {
	now := time.Now()
	exp := now.Add(ttl)
	claims := accessClaims{
		SID: sid,
		Typ: "access",
		RegisteredClaims: jwt.RegisteredClaims{
			ID:        randomID(),
			Subject:   strconv.FormatInt(userID, 10),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(exp),
		},
	}
	s, err := jwt.NewWithClaims(method, claims).SignedString(key)
	return s, exp, err
}

func randomID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// authMiddleware Bearer access token dogrular; "userID" ve "sid" degerlerini context'e koyar.
// alive nil degilse oturumun iptal edilmedigi DB'den kontrol edilir.
func authMiddleware(secret []byte, alive func(sid string) (bool, error)) gin.HandlerFunc {
	return authMiddlewareWith(hmacVerifier(secret), alive)
}

// authMiddlewareWith authMiddleware'in dogrulayici (HS256 ya da EdDSA) alan halidir.
func authMiddlewareWith(v accessVerifier, alive func(sid string) (bool, error)) gin.HandlerFunc {
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
			ok, err := alive(claims.SID)
			if err != nil {
				c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"error": "internal error", "code": "internal"})
				return
			}
			if !ok {
				c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "session revoked", "code": "session_revoked"})
				return
			}
		}
		c.Set("userID", id)
		c.Set("sid", claims.SID)
		c.Next()
	}
}
