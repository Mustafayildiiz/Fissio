package main

import (
	"bytes"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func postScan(t *testing.T, field string, data []byte) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	if field != "" {
		fw, _ := mw.CreateFormFile(field, "receipt.jpg")
		fw.Write(data)
	}
	mw.Close()
	req := httptest.NewRequest(http.MethodPost, "/receipts/scan", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	w := httptest.NewRecorder()
	r := gin.New()
	r.POST("/receipts/scan", (&handler{}).scanReceipt)
	r.ServeHTTP(w, req)
	return w
}

func TestScanReceiptRejectsBadUploads(t *testing.T) {
	if w := postScan(t, "", nil); w.Code != http.StatusBadRequest {
		t.Fatalf("missing file: got %d", w.Code)
	}
	if w := postScan(t, "file", nil); w.Code != http.StatusBadRequest {
		t.Fatalf("empty file: got %d", w.Code)
	}
	if w := postScan(t, "file", make([]byte, maxReceiptImageBytes+1)); w.Code != http.StatusBadRequest {
		t.Fatalf("oversized file: got %d", w.Code)
	}
}
