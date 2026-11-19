package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHTTPPurgerCallsExpenseInternalAPI(t *testing.T) {
	var gotMethod, gotPath, gotToken string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotToken = r.Method, r.URL.Path, r.Header.Get(internalTokenHeader)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	p := newHTTPPurger(srv.URL+"/", "secret-token")
	if err := p.PurgeUser(context.Background(), 42); err != nil {
		t.Fatalf("purge: %v", err)
	}
	if gotMethod != "DELETE" || gotPath != "/internal/users/42" || gotToken != "secret-token" {
		t.Fatalf("request = %s %s token=%q", gotMethod, gotPath, gotToken)
	}
}

func TestHTTPPurgerReportsFailures(t *testing.T) {
	// Sunucu hatasi ve yetkisiz yanit hata sayilir (auth satirlari silinmez, silme yeniden denenir).
	for _, status := range []int{http.StatusInternalServerError, http.StatusUnauthorized, http.StatusBadRequest} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(status)
		}))
		if err := newHTTPPurger(srv.URL, "t").PurgeUser(context.Background(), 1); err == nil {
			t.Errorf("status %d must be an error", status)
		}
		srv.Close()
	}
	// Ulasilamayan servis.
	down := httptest.NewServer(http.NotFoundHandler())
	url := down.URL
	down.Close()
	if err := newHTTPPurger(url, "t").PurgeUser(context.Background(), 1); err == nil {
		t.Error("unreachable expense must be an error")
	}
}

func TestLoadConfigRequiresInternalToken(t *testing.T) {
	t.Setenv("JWT_ACCESS_SECRET", "a")
	t.Setenv("INTERNAL_TOKEN", "")
	if _, err := loadConfig(); err == nil {
		t.Fatal("INTERNAL_TOKEN must be required")
	}
	t.Setenv("INTERNAL_TOKEN", "tok")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.internalToken != "tok" || cfg.expenseInternalURL != "http://expense:9090" || cfg.internalPort != "9090" {
		t.Fatalf("defaults: %+v", cfg)
	}
}
