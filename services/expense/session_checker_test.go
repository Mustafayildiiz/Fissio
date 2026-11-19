package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// sessionChecker, auth'un ic API'sine karsi (DB gerektirmez).

func TestSessionCheckerAliveRevokedAndOwnership(t *testing.T) {
	f := newFakeAuth(t)
	chk := newSessionChecker(f.url(), testInternalToken, 0)
	sid := f.newSession(7)

	if ok, err := chk.alive(sid, 7); !ok || err != nil {
		t.Fatalf("alive session: ok=%v err=%v", ok, err)
	}
	// Baska kullanicinin oturumu: token'daki sub != oturum sahibi -> reddedilir.
	if ok, err := chk.alive(sid, 8); ok || err != nil {
		t.Fatalf("foreign session must be rejected: ok=%v err=%v", ok, err)
	}
	// Bilinmeyen ve bicimi bozuk oturum: iptal sayilir, hata degil.
	if ok, err := chk.alive("00000000-0000-0000-0000-000000000000", 7); ok || err != nil {
		t.Fatalf("unknown session: ok=%v err=%v", ok, err)
	}
	if ok, err := chk.alive("not-a-uuid", 7); ok || err != nil {
		t.Fatalf("malformed sid: ok=%v err=%v", ok, err)
	}
	f.revoke(sid)
	if ok, err := chk.alive(sid, 7); ok || err != nil {
		t.Fatalf("revoked session: ok=%v err=%v", ok, err)
	}
}

func TestSessionCheckerCachesBriefly(t *testing.T) {
	f := newFakeAuth(t)
	sid := f.newSession(1)
	cached := newSessionChecker(f.url(), testInternalToken, time.Hour)
	if ok, err := cached.alive(sid, 1); !ok || err != nil {
		t.Fatalf("alive: %v %v", ok, err)
	}
	f.revoke(sid)
	before := f.hitCount()
	if ok, _ := cached.alive(sid, 1); !ok {
		t.Fatal("result should be served from cache within ttl")
	}
	if f.hitCount() != before {
		t.Fatal("cached lookup must not call auth again")
	}
	if ok, _ := newSessionChecker(f.url(), testInternalToken, 0).alive(sid, 1); ok {
		t.Fatal("uncached check must see the revocation")
	}
}

func TestSessionCheckerUnavailable(t *testing.T) {
	// Yanlis token (auth 401 doner): iptal degil, dogrulama yapilamiyor -> errAuthUnavailable.
	f := newFakeAuth(t)
	sid := f.newSession(1)
	if _, err := newSessionChecker(f.url(), "wrong-token", 0).alive(sid, 1); err != errAuthUnavailable {
		t.Fatalf("wrong token: err=%v", err)
	}
	// 5xx
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer bad.Close()
	if _, err := newSessionChecker(bad.URL, testInternalToken, 0).alive(sid, 1); err != errAuthUnavailable {
		t.Fatalf("5xx: err=%v", err)
	}
	// Ulasilamayan servis.
	down := httptest.NewServer(http.NotFoundHandler())
	url := down.URL
	down.Close()
	if _, err := newSessionChecker(url, testInternalToken, 0).alive(sid, 1); err != errAuthUnavailable {
		t.Fatalf("unreachable: err=%v", err)
	}
	// Unavailable sonuclari onbellege YAZILMAZ (gecici hata kalici red olmasin).
	chk := newSessionChecker(f.url(), testInternalToken, time.Hour)
	chk.token = "wrong-token"
	_, _ = chk.alive(sid, 1)
	chk.token = testInternalToken
	if ok, err := chk.alive(sid, 1); !ok || err != nil {
		t.Fatalf("recovery after transient failure: ok=%v err=%v", ok, err)
	}
}
