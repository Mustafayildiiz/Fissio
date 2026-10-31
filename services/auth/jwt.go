package main

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

const tokenTTL = 24 * time.Hour

func issueToken(secret []byte, userID int64) (string, time.Time, error) {
	exp := time.Now().Add(tokenTTL)
	claims := jwt.RegisteredClaims{
		Subject:   strconv.FormatInt(userID, 10),
		IssuedAt:  jwt.NewNumericDate(time.Now()),
		ExpiresAt: jwt.NewNumericDate(exp),
	}
	s, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(secret)
	return s, exp, err
}

// authMiddleware Bearer JWT dogrular ve "userID" degerini context'e koyar (FR-1.4).
func authMiddleware(secret []byte) gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.GetHeader("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing bearer token"})
			return
		}
		claims := &jwt.RegisteredClaims{}
		tok, err := jwt.ParseWithClaims(strings.TrimPrefix(h, "Bearer "), claims,
			func(t *jwt.Token) (any, error) { return secret, nil },
			jwt.WithValidMethods([]string{"HS256"}))
		if err != nil || !tok.Valid {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid or expired token"})
			return
		}
		id, err := strconv.ParseInt(claims.Subject, 10, 64)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid token subject"})
			return
		}
		c.Set("userID", id)
		c.Next()
	}
}

