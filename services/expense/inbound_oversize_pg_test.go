package main

import (
	"net/http/httptest"
	"strings"
	"testing"
)

// Boyut sınırı / yönlendirici reddi: geçerli alias'a gelen ama işlenemeyen mail kullanıcının aktarım geçmişine
// anlaşılır bir nedenle ("too_large") düşer; ham message/rfc822 yolu RFC 2047 başlıkları çözer.

// hookRaw webhook'u Cloudflare Worker gibi ham MIME + ?rcpt= ile çağırır.
func (e *xenv) hookRaw(rcpt, raw string) int {
	e.t.Helper()
	req := httptest.NewRequest("POST", "/webhooks/inbound-email?rcpt="+rcpt, strings.NewReader(raw))
	req.Header.Set("Content-Type", "message/rfc822")
	req.Header.Set("X-Webhook-Secret", testWebhookSecret)
	w := httptest.NewRecorder()
	e.r.ServeHTTP(w, req)
	return w.Code
}

func TestPGInboundOversizeRecordedInHistory(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	addr := e.inboundAddress(u).Address

	// (a) Sunucu sınırını aşan ham gövde: 413, ama ?rcpt= alias'ı çözdüğü için geçmişte "too_large".
	e.h.inbound.MaxBytes = 200
	big := "From: shop@example.com\r\nSubject: Fatura\r\n\r\n" + strings.Repeat("x", 1000)
	if st := e.hookRaw(addr, big); st != 413 {
		t.Fatalf("413 beklenir: %d", st)
	}
	e.h.inbound.MaxBytes = 0
	h := e.history(u, "")
	if len(h.Items) != 1 || h.Items[0].Status != "ignored" || h.Items[0].Reason != "too_large" {
		t.Fatalf("413 geçmişe düşmeli: %+v", h.Items)
	}
	if info := e.inboundAddress(u); info.LastStatus == nil || *info.LastStatus != "ignored:too_large" || info.LastReceivedAt == nil {
		t.Fatalf("last_status: %+v", info)
	}

	// Bilinmeyen alias'a 413: kimsenin geçmişine yazılmaz.
	e.h.inbound.MaxBytes = 200
	if st := e.hookRaw("nobody@"+testInboundDomain, big); st != 413 {
		t.Fatalf("413 beklenir: %d", st)
	}
	e.h.inbound.MaxBytes = 0
	if h := e.history(u, ""); len(h.Items) != 1 {
		t.Fatalf("yabancı alias geçmişe yazmamalı: %+v", h.Items)
	}

	// (b) Worker'ın gövdesiz boyut bildirimi: 200 ignored, RFC 2047 başlıklar çözülmüş olarak geçmişte.
	st, out := e.hook(testWebhookSecret, map[string]any{
		"to": addr, "from": "=?UTF-8?Q?Elektrik_=C5=9Eirketi?= <fatura@enerji.example>",
		"subject": "=?UTF-8?B?S2FzxLFtIEZhdHVyYW7EsXo=?=", "rejected": "too_large", "size": 30 << 20,
	})
	if st != 200 || out["status"] != "ignored" || out["reason"] != "too_large" {
		t.Fatalf("bildirim: %d %v", st, out)
	}
	h = e.history(u, "")
	if it := h.Items[0]; it.Reason != "too_large" || it.Subject != "Kasım Faturanız" || !strings.Contains(it.From, "Elektrik Şirketi") {
		t.Fatalf("bildirim geçmişi: %+v", it)
	}
	if n := len(e.list(u, "")); n != 0 {
		t.Fatalf("bildirim fiş üretmemeli: %d", n)
	}

	// Bilinmeyen "rejected" değeri bildirim sayılmaz (normal mail gibi işlenir → tutar yok).
	st, out = e.hook(testWebhookSecret, map[string]any{"to": addr, "text": "merhaba", "rejected": "whatever"})
	if st != 200 || out["reason"] != "no_amount" {
		t.Fatalf("bilinmeyen rejected: %d %v", st, out)
	}
}

// Ham rfc822 yolu (rawBytes): RFC 2047 konu/gönderen çözülür, fiş kaydedilir.
func TestPGInboundRawRFC822Headers(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	addr := e.inboundAddress(u).Address
	raw := "From: =?UTF-8?Q?K=C3=B6=C5=9Feba=C5=9F=C4=B1_D=C3=B6ner?= <siparis@kosebasi.example>\r\n" +
		"To: kullanici@gmail.com\r\n" +
		"Subject: =?UTF-8?B?U2lwYXJpxZ8gw5Z6ZXRp?=\r\n" +
		"MIME-Version: 1.0\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n" + yemeksepetiHTML
	if st := e.hookRaw(addr, raw); st != 200 {
		t.Fatalf("ham mail: %d", st)
	}
	h := e.history(u, "")
	if len(h.Items) != 1 || h.Items[0].Status != "saved" || h.Items[0].Subject != "Sipariş Özeti" ||
		!strings.Contains(h.Items[0].From, "Köşebaşı Döner") {
		t.Fatalf("geçmiş: %+v", h.Items)
	}
	if n := len(e.list(u, "")); n != 1 {
		t.Fatalf("1 fiş beklenir: %d", n)
	}
}
