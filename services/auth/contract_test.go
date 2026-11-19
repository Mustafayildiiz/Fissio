package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

// expense/contract_test.go ile AYNI beklentiler: iki servis ayni durumda ayni `code` degerini vermeli (mobil istemci
// yalnizca `code` alanina bakar). Auth'a ozgu `session_revoked` / `internal` kodlari burada sabitlenir.
func TestErrorCodeContractWithExpense(t *testing.T) {
	gin.SetMode(gin.TestMode)
	secret := []byte("contract-secret-contract-secret-0")
	good, _, _ := issueAccessToken(secret, 7, "s1", time.Minute)

	call := func(alive func(string) (bool, error), token string) (int, string) {
		r := gin.New()
		r.GET("/x", authMiddleware(secret, alive), func(c *gin.Context) { c.Status(http.StatusNoContent) })
		req := httptest.NewRequest(http.MethodGet, "/x", nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		var body struct {
			Code string `json:"code"`
		}
		_ = json.Unmarshal(w.Body.Bytes(), &body)
		return w.Code, body.Code
	}
	cases := []struct {
		name  string
		alive func(string) (bool, error)
		token string
		code  int
		want  string
	}{
		{"token yok", nil, "", 401, "unauthorized"},
		{"bozuk token", nil, "xxx", 401, "unauthorized"},
		{"iptal edilmis oturum", func(string) (bool, error) { return false, nil }, good, 401, "session_revoked"},
		{"beklenmeyen hata", func(string) (bool, error) { return false, http.ErrAbortHandler }, good, 500, "internal"},
		{"gecerli", func(string) (bool, error) { return true, nil }, good, 204, ""},
	}
	for _, c := range cases {
		code, got := call(c.alive, c.token)
		if code != c.code || got != c.want {
			t.Errorf("%s: %d/%q, beklenen %d/%q", c.name, code, got, c.code, c.want)
		}
	}
}
