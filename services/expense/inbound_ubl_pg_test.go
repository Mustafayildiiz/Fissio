package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"fissio/expense/internal/digital"
)

// UBL-TR XML eki + PDF + HTML çok parçalı mailler, platform HTML tablo kalemleri ve aktarım geçmişi.
// Gerçek Postgres; YIKICIDIR (bkz. isolation_pg_test.go).

const ublInvoiceXML = `<?xml version="1.0" encoding="UTF-8"?>
<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
  xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
  xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
  <cbc:ID>ABL2026000001234</cbc:ID>
  <cbc:UUID>F47AC10B-58CC-4372-A567-0E02B2C3D479</cbc:UUID>
  <cbc:IssueDate>2026-11-14</cbc:IssueDate>
  <cbc:DocumentCurrencyCode>TRY</cbc:DocumentCurrencyCode>
  <cac:AccountingSupplierParty><cac:Party><cac:PartyName><cbc:Name>ABLUKA Teknoloji A.Ş.</cbc:Name></cac:PartyName></cac:Party></cac:AccountingSupplierParty>
  <cac:LegalMonetaryTotal><cbc:PayableAmount currencyID="TRY">216.00</cbc:PayableAmount></cac:LegalMonetaryTotal>
  <cac:InvoiceLine><cbc:InvoicedQuantity>2</cbc:InvoicedQuantity><cbc:LineExtensionAmount>100.00</cbc:LineExtensionAmount><cac:Item><cbc:Name>Bulut Depolama</cbc:Name></cac:Item></cac:InvoiceLine>
  <cac:InvoiceLine><cbc:InvoicedQuantity>1</cbc:InvoicedQuantity><cbc:LineExtensionAmount>80.00</cbc:LineExtensionAmount><cac:Item><cbc:Name>Destek Paketi</cbc:Name></cac:Item></cac:InvoiceLine>
</Invoice>`

func b64MIME(b []byte) string {
	s := base64.StdEncoding.EncodeToString(b)
	var out []string
	for len(s) > 76 {
		out = append(out, s[:76])
		s = s[76:]
	}
	return strings.Join(append(out, s), "\r\n")
}

// earsivMIME: "ABLUKA e-Arşiv Faturanız" — gövdede tutar yok; HTML + PDF + XML ekleri.
func earsivMIME(xml string) string {
	return "From: ABLUKA e-Arsiv <earsiv@abluka.example>\r\nSubject: ABLUKA e-Arsiv Faturaniz\r\nMIME-Version: 1.0\r\n" +
		"Content-Type: multipart/mixed; boundary=\"mix\"\r\n\r\n" +
		"--mix\r\nContent-Type: multipart/alternative; boundary=\"alt\"\r\n\r\n" +
		"--alt\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nFaturaniz ektedir.\r\n" +
		"--alt\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<p>Faturaniz ektedir.</p>\r\n--alt--\r\n" +
		"--mix\r\nContent-Type: application/pdf; name=\"fatura.pdf\"\r\nContent-Transfer-Encoding: base64\r\n" +
		"Content-Disposition: attachment; filename=\"fatura.pdf\"\r\n\r\n" + b64MIME([]byte("%PDF-1.4 fake")) + "\r\n" +
		"--mix\r\nContent-Type: application/xml; name=\"fatura.xml\"\r\nContent-Transfer-Encoding: base64\r\n" +
		"Content-Disposition: attachment; filename=\"fatura.xml\"\r\n\r\n" + b64MIME([]byte(xml)) + "\r\n--mix--\r\n"
}

func TestPGInboundUBLAttachmentWinsOverPDFAndHTML(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	// PDF metin katmanı BAŞKA bir tutar/belge taşısa bile XML kazanır ve mail tek fiş olur.
	e.h.inbound.PDFText = func([]byte) ([]string, error) { return []string{officialInvoiceText}, nil }

	st, out := e.mail(u, map[string]any{"raw": earsivMIME(ublInvoiceXML)})
	if st != 200 || out["status"] != "created" {
		t.Fatalf("ubl: %d %v", st, out)
	}
	list := e.list(u, "")
	if len(list) != 1 {
		t.Fatalf("tek fiş beklenir: %d", len(list))
	}
	g := list[0]
	if g.Merchant != "ABLUKA Teknoloji A.Ş." || g.Amount != 216 || g.Date != "2026-11-14" ||
		g.OcrEngine == nil || *g.OcrEngine != "xml" || g.DocumentNo == nil || *g.DocumentNo != "f47ac10b-58cc-4372-a567-0e02b2c3d479" ||
		!g.HasOfficialInvoice {
		t.Fatalf("kayıt: %+v", g)
	}
	names := []string{}
	var sum float64
	for _, it := range g.Items {
		names = append(names, it.Name)
		sum += it.Amount
	}
	if strings.Join(names, "|") != "2 x Bulut Depolama|Destek Paketi|KDV" || sum != 216 {
		t.Fatalf("kalemler: %v toplam %v", names, sum)
	}

	// Aynı mail yeniden (sağlayıcı yeniden denemesi / çift iletim): mükerrer kayıt açılmaz.
	st, out = e.mail(u, map[string]any{"raw": earsivMIME(ublInvoiceXML)})
	if st != 200 || out["status"] != "duplicate" {
		t.Fatalf("tekrar: %d %v", st, out)
	}
	if n := len(e.list(u, "")); n != 1 {
		t.Fatalf("kayıt sayısı: %d", n)
	}
}

func TestPGInboundBrokenXMLFallsBackToPDFThenHTML(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	e.h.inbound.PDFText = func([]byte) ([]string, error) { return []string{officialInvoiceText}, nil }
	st, out := e.mail(u, map[string]any{"raw": earsivMIME("<Invoice><ID>1</Invoice>")})
	if st != 200 || out["status"] != "created" {
		t.Fatalf("pdf düşüşü: %d %v", st, out)
	}
	if g := e.list(u, ""); len(g) != 1 || g[0].OcrEngine == nil || *g[0].OcrEngine != "pdf" {
		t.Fatalf("pdf kaydı: %+v", g)
	}

	// XML bozuk, PDF okunamıyor, HTML gövdede tutar yok → ignored (fiş açılmaz).
	e2 := newXEnv(t)
	e2.enableInbound()
	e2.h.inbound.PDFText = func([]byte) ([]string, error) { return nil, digital.ErrPDFUnreadable }
	st, out = e2.mail(u, map[string]any{"raw": earsivMIME("<Invoice><ID>1</Invoice>")})
	if st != 200 || out["status"] != "ignored" {
		t.Fatalf("hepsi başarısız: %d %v", st, out)
	}
}

// Birim fiyatlı sütunlar ve teslimat ücreti: tablo kalemleri adet ve satır tutarıyla kaydedilir.
const yemeksepetiItemsHTML = `<html><body><table>
<tr><td>Restoran</td><td>Köşebaşı Döner</td></tr><tr><td>Sipariş No</td><td>YS-9C2D41AB</td></tr>
<tr><td>Sipariş Tarihi</td><td>16.11.2026 20:10</td></tr>
<tr><th>Ürün</th><th>Adet</th><th>Birim</th><th>Tutar</th></tr>
<tr><td>Tavuk Döner Porsiyon</td><td>2</td><td>92,50 TL</td><td>185,00 TL</td></tr>
<tr><td>Ayran</td><td>1</td><td>15,00 TL</td><td>15,00 TL</td></tr>
<tr><td>Teslimat Ücreti</td><td>12,90 TL</td></tr>
<tr><td>Ara Toplam</td><td>212,90 TL</td></tr>
<tr><td><b>Genel Toplam</b></td><td><b>212,90 TL</b></td></tr></table></body></html>`

func TestPGInboundPlatformHTMLItemsWithQuantity(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	st, out := e.mail(u, map[string]any{"html": yemeksepetiItemsHTML, "from": "Yemeksepeti <info@yemeksepeti.example>"})
	if st != 200 || out["status"] != "created" {
		t.Fatalf("yemeksepeti: %d %v", st, out)
	}
	g := e.list(u, "")
	if len(g) != 1 || g[0].Amount != 212.9 {
		t.Fatalf("kayıt: %+v", g)
	}
	got := map[string]float64{}
	for _, it := range g[0].Items {
		got[it.Name] = it.Amount
	}
	want := map[string]float64{"2 x Tavuk Döner Porsiyon": 185, "Ayran": 15, "Teslimat Ücreti": 12.9}
	if len(got) != len(want) {
		t.Fatalf("kalemler: %v", got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Fatalf("kalemler: %v", got)
		}
	}
}

type historyResp struct {
	Enabled bool `json:"enabled"`
	Items   []struct {
		ID         int64  `json:"id"`
		Source     string `json:"source"`
		From       string `json:"from"`
		Subject    string `json:"subject"`
		ReceivedAt string `json:"received_at"`
		Status     string `json:"status"`
		Reason     string `json:"reason"`
		ExpenseID  *int64 `json:"expense_id"`
	} `json:"items"`
}

func (e *xenv) history(uid int64, query string) historyResp {
	e.t.Helper()
	code, b := e.as(uid, "GET", "/inbound-address/history"+query, nil)
	e.want(code, 200, b, "history")
	var out historyResp
	if err := json.Unmarshal(b, &out); err != nil {
		e.t.Fatal(err)
	}
	return out
}

func TestPGInboundHistory(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u1, u2 = int64(1), int64(2)
	e.h.inbound.PDFText = func([]byte) ([]string, error) { return []string{officialInvoiceText}, nil }

	if h := e.history(u1, ""); !h.Enabled || len(h.Items) != 0 {
		t.Fatalf("başlangıçta boş: %+v", h)
	}
	e.mail(u1, map[string]any{"raw": earsivMIME(ublInvoiceXML), "subject": "ABLUKA e-Arşiv Faturanız"}) // saved
	e.mail(u1, map[string]any{"raw": earsivMIME(ublInvoiceXML)})                                        // duplicate
	e.mail(u1, map[string]any{"text": "Merhaba, hiç rakam yok.", "subject": "Selam"})                   // no_amount
	e.mail(u2, map[string]any{"html": yemeksepetiHTML})                                                 // başka kullanıcı

	h := e.history(u1, "")
	if len(h.Items) != 3 {
		t.Fatalf("3 satır beklenir: %+v", h.Items)
	}
	// yeniden eskiye
	no, dup, saved := h.Items[0], h.Items[1], h.Items[2]
	if no.Status != "ignored" || no.Reason != "no_amount" || no.Subject != "Selam" || no.ExpenseID != nil || no.Source != "email" {
		t.Fatalf("no_amount: %+v", no)
	}
	list := e.list(u1, "")
	if saved.Status != "saved" || saved.Reason != "created" || saved.ExpenseID == nil || *saved.ExpenseID != list[0].ID ||
		saved.Subject != "ABLUKA e-Arsiv Faturaniz" || // ham MIME başlığı JSON `subject` alanından önceliklidir
		!strings.Contains(saved.From, "ABLUKA") {
		t.Fatalf("saved: %+v (list %+v)", saved, list[0])
	}
	if dup.Status != "ignored" || dup.ExpenseID == nil || *dup.ExpenseID != list[0].ID {
		t.Fatalf("duplicate: %+v", dup)
	}
	if h2 := e.history(u2, ""); len(h2.Items) != 1 || h2.Items[0].Status != "saved" {
		t.Fatalf("u2 yalnız kendi geçmişini görür: %+v", h2.Items)
	}
	if h := e.history(u1, "?limit=1"); len(h.Items) != 1 {
		t.Fatalf("limit: %+v", h.Items)
	}

	// failed durumu + kontrol karakteri/uzunluk temizliği + kullanıcı başına 50 sınırı.
	e.h.recordInboundHistory(u1, "a\x00b <x@y.z>", strings.Repeat("ş", 500)+"\nsatır", historyFailed, "db_error", 0)
	h = e.history(u1, "")
	if h.Items[0].Status != "failed" || len([]rune(h.Items[0].Subject)) != historyFieldRunes || strings.ContainsAny(h.Items[0].From, "\x00") {
		t.Fatalf("failed/temizlik: %+v", h.Items[0])
	}
	for i := 0; i < inboundHistoryKept+5; i++ {
		e.h.recordInboundHistory(u1, "x", "y", historyIgnored, "no_amount", 0)
	}
	var n int
	if err := e.h.db.QueryRow(`SELECT count(*) FROM expense.inbound_history WHERE user_id = $1`, u1).Scan(&n); err != nil || n != inboundHistoryKept {
		t.Fatalf("kırpma: n=%d err=%v", n, err)
	}
	if h := e.history(u1, "?limit=500"); len(h.Items) != inboundHistoryKept {
		t.Fatalf("üst sınır: %d", len(h.Items))
	}
}

func TestPGInboundHistoryDisabled(t *testing.T) {
	e := newXEnv(t) // inbound kapalı
	if h := e.history(1, ""); h.Enabled || len(h.Items) != 0 {
		t.Fatalf("kapalıyken boş liste: %+v", h)
	}
}
