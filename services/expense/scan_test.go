package main

import (
	"bytes"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

// postFiles, verilen sayida "file" parcasi iceren multipart istegi atar (handler: dogrulama katmani;
// DB/OCR'a ulasmadan once reddedilen durumlari sinar).
func postFiles(t *testing.T, path string, handlerFunc gin.HandlerFunc, sizes ...int) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	for _, n := range sizes {
		fw, _ := mw.CreateFormFile("file", "receipt.jpg")
		fw.Write(make([]byte, n))
	}
	mw.Close()
	req := httptest.NewRequest(http.MethodPost, path, &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	w := httptest.NewRecorder()
	r := gin.New()
	r.POST(path, handlerFunc)
	r.ServeHTTP(w, req)
	return w
}

func TestScanReceiptRejectsBadUploads(t *testing.T) {
	h := (&handler{}).scanReceipt
	const p = "/receipts/scan"
	if w := postFiles(t, p, h); w.Code != http.StatusBadRequest {
		t.Fatalf("missing file: got %d", w.Code)
	}
	if w := postFiles(t, p, h, 0); w.Code != http.StatusBadRequest {
		t.Fatalf("empty file: got %d", w.Code)
	}
	if w := postFiles(t, p, h, maxImageBytes+1); w.Code != http.StatusBadRequest {
		t.Fatalf("oversized single file: got %d", w.Code)
	}
	pages := make([]int, maxScanPages+1)
	for i := range pages {
		pages[i] = 10
	}
	if w := postFiles(t, p, h, pages...); w.Code != http.StatusBadRequest {
		t.Fatalf("too many pages: got %d", w.Code)
	}
	// Toplam sinir (30 MB) asilinca 413.
	big := []int{maxImageBytes, maxImageBytes, maxImageBytes, maxImageBytes, maxImageBytes, maxImageBytes, maxImageBytes}
	if w := postFiles(t, p, h, big...); w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("total over limit: got %d", w.Code)
	}
}

func TestImageEndpointsRejectBadIDs(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	h := &handler{}
	r.POST("/expenses/:id/images", h.uploadImages)
	r.GET("/expenses/:id/images/:imageId", h.getImage)
	r.DELETE("/expenses/:id/images/:imageId", h.deleteImage)
	for _, c := range []struct{ method, path string }{
		{http.MethodPost, "/expenses/abc/images"},
		{http.MethodGet, "/expenses/1/images/xyz"},
		{http.MethodDelete, "/expenses/x/images/1"},
	} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(c.method, c.path, nil))
		if w.Code != http.StatusBadRequest {
			t.Errorf("%s %s: got %d, want 400", c.method, c.path, w.Code)
		}
	}
}
