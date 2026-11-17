package main

import (
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

// ipLimiter: IP basina sabit pencere sayaci (bellek ici; tek instance icin yeterli).
type ipLimiter struct {
	mu     sync.Mutex
	window time.Duration
	max    int
	hits   map[string]*hitWindow
	now    func() time.Time
}

type hitWindow struct {
	start time.Time
	count int
}

func newIPLimiter(max int, w time.Duration) *ipLimiter {
	return &ipLimiter{window: w, max: max, hits: map[string]*hitWindow{}, now: time.Now}
}

func (l *ipLimiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	t := l.now()
	if len(l.hits) > 10000 { // basit temizlik
		for k, v := range l.hits {
			if t.Sub(v.start) > l.window {
				delete(l.hits, k)
			}
		}
	}
	w := l.hits[ip]
	if w == nil || t.Sub(w.start) > l.window {
		l.hits[ip] = &hitWindow{start: t, count: 1}
		return true
	}
	w.count++
	return w.count <= l.max
}

func (l *ipLimiter) middleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if !l.allow(c.ClientIP()) {
			c.Header("Retry-After", "60")
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "too many requests", "code": "rate_limited"})
			return
		}
		c.Next()
	}
}
