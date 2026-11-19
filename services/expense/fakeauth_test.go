package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

const testInternalToken = "test-internal-token"

// fakeAuth auth servisinin ic API'sinin (GET /internal/sessions/:sid) bellek ici taklidi. Expense testleri
// artik auth semasina/tablosuna hic dokunmaz; oturum dogrulamasi gercek HTTP yoluyla (sessionChecker) calisir.
type fakeAuth struct {
	t        *testing.T
	srv      *httptest.Server
	mu       sync.Mutex
	sessions map[string]*fakeSession
	hits     int
}

type fakeSession struct {
	userID  int64
	revoked bool
}

func newFakeAuth(t *testing.T) *fakeAuth {
	t.Helper()
	f := &fakeAuth{t: t, sessions: map[string]*fakeSession{}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeAuth) url() string { return f.srv.URL }

func (f *fakeAuth) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hits++
	if r.Header.Get(internalTokenHeader) != testInternalToken {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	sid := strings.TrimPrefix(r.URL.Path, "/internal/sessions/")
	if !strings.HasPrefix(r.URL.Path, "/internal/sessions/") || !looksLikeUUID(sid) {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	s, ok := f.sessions[sid]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"alive": !s.revoked, "user_id": s.userID})
}

func (f *fakeAuth) newSession(userID int64) string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	sid := fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
	f.mu.Lock()
	f.sessions[sid] = &fakeSession{userID: userID}
	f.mu.Unlock()
	return sid
}

func (f *fakeAuth) revoke(sid string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if s, ok := f.sessions[sid]; ok {
		s.revoked = true
	}
}

func (f *fakeAuth) hitCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits
}

func looksLikeUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		switch {
		case i == 8 || i == 13 || i == 18 || i == 23:
			if c != '-' {
				return false
			}
		case !strings.ContainsRune("0123456789abcdefABCDEF", c):
			return false
		}
	}
	return true
}
