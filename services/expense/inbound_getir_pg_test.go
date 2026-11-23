package main

import (
	"net/http"
	"strings"
	"testing"
)

// GetirYemek tarzı sipariş özeti + last_received_at semantiği + failed nedeni. Gerçek Postgres; YIKICIDIR
// (bkz. isolation_pg_test.go).

// Gerçek GetirYemek HTML yapısı: solda ürün adı + adet (FİYATSIZ), sağda "Sipariş Özeti" tablosu; tutarlar ondalıksız ve
// para birimi bitişik ("355TRY") ya da boşluklu ("665 TRY"); kampanya indirimi adında "indirim" geçmeyen NEGATİF satır.
const getirYemekHTML = `<html><body>
<table width="600"><tr><td colspan="2"><h2>Siparişin teslim edildi, afiyet olsun!</h2></td></tr>
<tr>
 <td width="320"><p>Tavukburger® Menü Alana Tavukburger® Menü Hediye - (Adet: 1)</p></td>
 <td width="280"><table>
   <tr><td colspan="2"><b>Sipariş Özeti</b></td></tr>
   <tr><td>Ara Toplam</td><td>665 TRY</td></tr>
   <tr><td>Teslimat Ücreti</td><td>0 TRY</td></tr>
   <tr><td>Tavukburger® Menü Alana Tavukburger® Menü Hediye</td><td>-310 TRY</td></tr>
   <tr><td><b>Toplam</b></td><td><b>355TRY</b></td></tr>
 </table></td></tr></table>
<p>Abonelikten çık | Gizlilik Politikası</p></body></html>`

func TestPGInboundGetirYemekIntegerCurrencyAndNegativeDiscount(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	st, out := e.mail(u, map[string]any{"html": getirYemekHTML, "from": "GetirYemek <noreply@getiryemek.example>", "subject": "Siparişin teslim edildi"})
	if st != 200 || out["status"] != "created" {
		t.Fatalf("getir: %d %v", st, out)
	}
	list := e.list(u, "")
	if len(list) != 1 {
		t.Fatalf("1 kayıt beklenir: %d", len(list))
	}
	g := list[0]
	if g.Amount != 355.0 {
		t.Fatalf("tutar = %v, want 355 (Toplam 355TRY; ara toplam/indirim/teslimat toplamı bozmamalı)", g.Amount)
	}
	if g.Merchant != "GetirYemek" {
		t.Fatalf("satıcı = %q, want GetirYemek (cümle başlık satıcı olmamalı)", g.Merchant)
	}
	if g.OcrEngine == nil || *g.OcrEngine != "email" {
		t.Fatalf("motor: %+v", g.OcrEngine)
	}
	// Fiyatsız ürün: fiyat uydurulmaz; net toplam tek kaleme yazılır (negatif indirim satırı kalem OLMAZ).
	if len(g.Items) != 1 || g.Items[0].Amount != 355 || !strings.Contains(g.Items[0].Name, "Tavukburger") {
		t.Fatalf("kalemler: %+v", g.Items)
	}
	if h := e.history(u, ""); len(h.Items) != 1 || h.Items[0].Status != "saved" || h.Items[0].ExpenseID == nil || *h.Items[0].ExpenseID != g.ID {
		t.Fatalf("geçmiş: %+v", h.Items)
	}
	if info := e.inboundAddress(u); info.LastReceivedAt == nil || info.LastStatus == nil || *info.LastStatus != "created" {
		t.Fatalf("durum: %+v", info)
	}
}

// Aynı yapı yönlendirilmiş gelirse (önsözlü düz metin, From = kullanıcının kendi adresi) satıcı önsözdeki göndericiden gelir.
func TestPGInboundGetirYemekForwardedByUser(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	text := "---------- Forwarded message ---------\nFrom: GetirYemek <noreply@getiryemek.example>\nDate: 21 Nov 2026\nSubject: Siparişin\nTo: kisi@gmail.com\n\n" +
		"Siparişin teslim edildi, afiyet olsun!\nTavukburger® Menü Alana Tavukburger® Menü Hediye - (Adet: 1)\nSipariş Özeti\n" +
		"Ara Toplam 665 TRY\nTeslimat Ücreti 0 TRY\nTavukburger® Menü Alana Tavukburger® Menü Hediye -310 TRY\nToplam 355TRY"
	st, out := e.mail(1, map[string]any{"text": text, "from": "Kişi <kisi@gmail.com>"})
	if st != 200 || out["status"] != "created" {
		t.Fatalf("%d %v", st, out)
	}
	g := e.list(1, "")[0]
	if g.Amount != 355 || g.Merchant != "GetirYemek" {
		t.Fatalf("%+v", g)
	}
}

func (e *xenv) lastInbound(uid int64) (status string, hasTime bool) {
	e.t.Helper()
	info := e.inboundAddress(uid)
	if info.LastStatus != nil {
		status = *info.LastStatus
	}
	return status, info.LastReceivedAt != nil
}

// Alias geçerli HER mail (saved / ignored / failed) last_status + last_received_at'i günceller; Gmail onayı güncellemez.
func TestPGInboundLastReceivedUpdatesOnEveryOutcome(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	if s, ok := e.lastInbound(u); ok || s != "" {
		t.Fatalf("başlangıç: %q %v", s, ok)
	}
	reset := func() {
		if _, err := e.db.Exec(`UPDATE expense.inbound_aliases SET last_received_at = '2020-01-01T00:00:00Z' WHERE user_id = $1`, u); err != nil {
			t.Fatal(err)
		}
	}
	stamp := func() string {
		var s string
		if err := e.db.QueryRow(`SELECT last_received_at::text FROM expense.inbound_aliases WHERE user_id = $1`, u).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}

	// 1) tutarı okunamayan mail (ignored) — eskiden last_received_at'e dokunmuyordu
	e.mail(u, map[string]any{"text": "Merhaba, hiç rakam yok.", "subject": "Selam"})
	if s, ok := e.lastInbound(u); !ok || s != "ignored:no_amount" {
		t.Fatalf("ignored: %q %v", s, ok)
	}
	// 2) ardışık ignored mail zamanı yeniden ilerletir
	reset()
	e.mail(u, map[string]any{"text": "Yine rakam yok."})
	if strings.HasPrefix(stamp(), "2020") {
		t.Fatal("ikinci ignored mail last_received_at'i ilerletmedi")
	}
	// 3) kaydedilen
	reset()
	e.mail(u, map[string]any{"html": getirYemekHTML, "from": "GetirYemek <noreply@getiryemek.example>"})
	if s, _ := e.lastInbound(u); s != "created" || strings.HasPrefix(stamp(), "2020") {
		t.Fatalf("created: %q %s", s, stamp())
	}
	// 4) yinelenen
	reset()
	e.mail(u, map[string]any{"html": getirYemekHTML, "from": "GetirYemek <noreply@getiryemek.example>"})
	if s, _ := e.lastInbound(u); !strings.HasPrefix(s, "duplicate") || strings.HasPrefix(stamp(), "2020") {
		t.Fatalf("duplicate: %q %s", s, stamp())
	}
	// 5) Gmail onay maili fiş aktarımı değil: last_received_at ilerlemez, last_status gmail_confirmation
	reset()
	body := "ahmet@gmail.com adresi bu adrese posta yönlendirmek istiyor.\nOnay kodu: 123456789\n" +
		"https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-abc"
	e.mail(u, map[string]any{"from": "Gmail Team <forwarding-noreply@google.com>", "subject": "Gmail Yönlendirme Onayı", "text": body})
	if s, _ := e.lastInbound(u); s != "gmail_confirmation" || !strings.HasPrefix(stamp(), "2020") {
		t.Fatalf("gmail onayı: %q %s", s, stamp())
	}
}

// failed: gerçek hata geçmişin `reason` alanına (kısaltılmış) yazılır ve last_received_at/last_status güncellenir.
func TestPGInboundFailedKeepsRealReason(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	// Her yeni satırı reddeden (NOT VALID: eski satırlara dokunmaz) kısıtlama → gerçek bir DB hatası.
	if _, err := e.db.Exec(`ALTER TABLE expense.expenses ADD CONSTRAINT boom_for_test CHECK (false) NOT VALID`); err != nil {
		t.Fatal(err)
	}
	st, _ := e.mail(u, map[string]any{"html": getirYemekHTML, "from": "GetirYemek <noreply@getiryemek.example>", "subject": "Siparişin"})
	if st != http.StatusInternalServerError {
		t.Fatalf("DB hatası 500 beklenir: %d", st)
	}
	h := e.history(u, "")
	if len(h.Items) != 1 || h.Items[0].Status != "failed" {
		t.Fatalf("geçmiş: %+v", h.Items)
	}
	r := h.Items[0].Reason
	if !strings.HasPrefix(r, "db_error: ") || !strings.Contains(r, "boom_for_test") {
		t.Fatalf("gerçek neden beklenir (db_error: …boom_for_test…): %q", r)
	}
	if len([]rune(r)) > len("db_error: ")+160 {
		t.Fatalf("neden kısaltılmalı: %d rune", len([]rune(r)))
	}
	if s, ok := e.lastInbound(u); !ok || s != "failed:db_error" {
		t.Fatalf("last_status/last_received_at: %q %v", s, ok)
	}
}
