package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"fissio/expense/internal/digital"
)

// E-posta ile otomatik fiş aktarımı: alias uçları, webhook (secret, alias çözümü, HTML/düz metin/PDF, birleştirme,
// mükerrer), Gmail onay yakalama. Gerçek Postgres; YIKICIDIR (bkz. isolation_pg_test.go).

const (
	testWebhookSecret = "webhook-secret-for-tests-0123456789"
	testInboundDomain = "fis.test"
)

func (e *xenv) enableInbound() {
	e.h.inbound = inboundConfig{Domain: testInboundDomain, Secret: testWebhookSecret}
}

// hook webhook'u JWT'siz, verilen secret ile çağırır.
func (e *xenv) hook(secret string, payload any) (int, map[string]any) {
	e.t.Helper()
	var body []byte
	switch v := payload.(type) {
	case []byte:
		body = v
	default:
		body, _ = json.Marshal(payload)
	}
	req := httptest.NewRequest("POST", "/webhooks/inbound-email", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if secret != "" {
		req.Header.Set("X-Webhook-Secret", secret)
	}
	w := httptest.NewRecorder()
	e.r.ServeHTTP(w, req)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

func (e *xenv) inboundAddress(uid int64) inboundInfo {
	e.t.Helper()
	code, b := e.as(uid, "GET", "/inbound-address", nil)
	e.want(code, 200, b, "inbound-address")
	var info inboundInfo
	if err := json.Unmarshal(b, &info); err != nil {
		e.t.Fatal(err)
	}
	return info
}

// to: kullanıcının alias adresi (zarf alıcısı).
func (e *xenv) mail(uid int64, extra map[string]any) (int, map[string]any) {
	e.t.Helper()
	m := map[string]any{"to": e.inboundAddress(uid).Address, "from": "Trendyol Go <noreply@trendyolgo.com>", "subject": "Sipariş Özeti"}
	for k, v := range extra {
		m[k] = v
	}
	return e.hook(testWebhookSecret, m)
}

const yemeksepetiHTML = `<html><body><div style="display:none">özet</div><table>
<tr><td>Restoran</td><td>Köşebaşı Döner</td></tr><tr><td>Sipariş No</td><td>YS-4F7A91C2</td></tr>
<tr><td>Sipariş Tarihi</td><td>14.11.2026 13:05</td></tr>
<tr><td>1 x Tavuk Döner Porsiyon</td><td>185,00 TL</td></tr><tr><td>1 x Ayran</td><td>25,00 TL</td></tr>
<tr><td><b>Toplam</b></td><td><b>210,00 TL</b></td></tr></table>
<p>Abonelikten çık | Gizlilik Politikası</p></body></html>`

const officialInvoiceText = `Köşebaşı Döner Restoran Ltd. Şti.
e-Arşiv Fatura
VKN: 1234567890
Fatura No: GIB2026000000123
ETTN: 3f2a9c1e-5b7d-4e8a-9c3d-1a2b3c4d5e6f
Sipariş No: YS-4F7A91C2
Tarih: 15.11.2026
Tavuk Döner Porsiyon 185,00
Ayran 25,00
Ödenecek Tutar: 212,50 TL`

func TestPGInboundAddressEndpoints(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)

	// Kapalıyken 200 {enabled:false}.
	code, b := e.as(alice, "GET", "/inbound-address", nil)
	e.want(code, 200, b, "disabled")
	if strings.Contains(string(b), "address") || !strings.Contains(string(b), `"enabled":false`) {
		t.Fatalf("kapalı özellik: %s", b)
	}

	e.enableInbound()
	a1 := e.inboundAddress(alice)
	if !a1.Enabled || !strings.HasSuffix(a1.Address, "@"+testInboundDomain) || len(a1.Address) != 16+1+len(testInboundDomain) {
		t.Fatalf("adres: %+v", a1)
	}
	if a2 := e.inboundAddress(alice); a2.Address != a1.Address {
		t.Fatalf("adres kararlı olmalı: %s != %s", a2.Address, a1.Address)
	}
	if b1 := e.inboundAddress(bob); b1.Address == a1.Address {
		t.Fatal("kullanıcılar farklı adres almalı")
	}

	// Profil seçimi: başkasının profili 404, kendisininki kabul.
	bobProfile := e.profiles(bob)[0]
	code, b = e.as(alice, "PUT", "/inbound-address", map[string]any{"profile_id": bobProfile.ID})
	e.want(code, 404, b, "başkasının profili")
	own := e.newProfile(alice, "İş")
	code, b = e.as(alice, "PUT", "/inbound-address", map[string]any{"profile_id": own.ID})
	e.want(code, 200, b, "kendi profili")
	if got := e.inboundAddress(alice); got.ProfileID == nil || *got.ProfileID != own.ID {
		t.Fatalf("profil seçilmedi: %+v", got)
	}

	// Yenileme: eski adres geçersiz olur.
	code, b = e.as(alice, "POST", "/inbound-address/rotate", nil)
	e.want(code, 200, b, "rotate")
	var rotated inboundInfo
	_ = json.Unmarshal(b, &rotated)
	if rotated.Address == a1.Address || rotated.Address == "" {
		t.Fatalf("rotate: %+v", rotated)
	}
	st, out := e.hook(testWebhookSecret, map[string]any{"to": a1.Address, "html": yemeksepetiHTML})
	if st != 200 || out["status"] != "ignored" || out["reason"] != "unknown_alias" {
		t.Fatalf("eski alias: %d %v", st, out)
	}
	// Onay yokken 204.
	code, b = e.as(alice, "GET", "/inbound-address/confirmation", nil)
	e.want(code, 204, b, "confirmation yok")
}

func TestPGInboundWebhookAuth(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	addr := e.inboundAddress(1).Address
	payload := map[string]any{"to": addr, "html": yemeksepetiHTML}

	for _, secret := range []string{"", "wrong", testWebhookSecret + "x"} {
		if st, _ := e.hook(secret, payload); st != 401 {
			t.Errorf("secret %q: %d", secret, st)
		}
	}
	// Sunucuda secret tanımsızsa HER istek reddedilir (boş secret = açık kapı değil).
	e.h.inbound.Secret = ""
	if st, _ := e.hook("", payload); st != 401 {
		t.Errorf("boş sunucu secret'ı: %d", st)
	}
	e.h.inbound.Secret = testWebhookSecret
	// Aşırı boyut 413.
	e.h.inbound.MaxBytes = 200
	if st, _ := e.hook(testWebhookSecret, payload); st != 413 {
		t.Errorf("büyük gövde: %d", st)
	}
	e.h.inbound.MaxBytes = 0
	// Özellik kapalıyken (domain yok) doğru secret bile fiş üretmez.
	e.h.inbound.Domain = ""
	if st, out := e.hook(testWebhookSecret, payload); st != 200 || out["status"] != "ignored" {
		t.Errorf("kapalı özellik: %d %v", st, out)
	}
}

func TestPGInboundHTMLThenOfficialInvoiceFlow(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)

	// 1) Otomatik yönlendirme: To: kullanıcının kendi Gmail'i, alias yalnızca zarf alıcısında.
	st, out := e.mail(u, map[string]any{"html": yemeksepetiHTML, "message_id": "<1@x>"})
	if st != 200 || out["status"] != "created" {
		t.Fatalf("HTML sipariş özeti: %d %v", st, out)
	}
	list := e.list(u, "")
	if len(list) != 1 {
		t.Fatalf("1 kayıt beklenir: %d", len(list))
	}
	pre := list[0]
	if pre.Amount != 210 || pre.OrderID == nil || *pre.OrderID != "YS-4F7A91C2" || pre.HasOfficialInvoice ||
		pre.OcrEngine == nil || *pre.OcrEngine != "email" || pre.Date != "2026-11-14" || len(pre.Items) != 2 {
		t.Fatalf("ön özet kaydı: %+v", pre)
	}
	if info := e.inboundAddress(u); info.LastReceivedAt == nil || info.LastStatus == nil || *info.LastStatus != "created" {
		t.Fatalf("durum: %+v", info)
	}

	// 2) Aynı mail ikinci kez iletilir (yeni Message-ID, "İlet" önsözü eklenmiş): yeni kayıt açılmaz.
	forwarded := "---------- Forwarded message ---------\nFrom: Yemeksepeti <info@ys.com>\nSubject: Siparişiniz\n\n" + digital.HTMLToText(yemeksepetiHTML)
	st, out = e.mail(u, map[string]any{"text": forwarded, "message_id": "<2@x>"})
	if st != 200 || out["status"] != "duplicate" || out["reason"] != "already_imported" {
		t.Fatalf("çift iletim: %d %v", st, out)
	}
	// Metni biraz farklı (ek satır) ama aynı sipariş: client_uid farklı olsa da order_id ile mükerrer yakalanır.
	st, out = e.mail(u, map[string]any{"text": forwarded + "\nBu mesaj iletilmiştir.", "message_id": "<3@x>"})
	if st != 200 || out["status"] != "duplicate" || out["reason"] != "duplicate_order" {
		t.Fatalf("aynı sipariş farklı metin: %d %v", st, out)
	}
	if n := len(e.list(u, "")); n != 1 {
		t.Fatalf("çift iletim kayıt açmamalı: %d", n)
	}

	// 3) Günler sonra resmi e-Arşiv faturası (düz metin) gelir: ön özete birleşir, kilitlenir.
	st, out = e.mail(u, map[string]any{"text": officialInvoiceText, "subject": "e-Arşiv Fatura"})
	if st != 200 || out["status"] != "merged" {
		t.Fatalf("resmi fatura: %d %v", st, out)
	}
	list = e.list(u, "")
	if len(list) != 1 {
		t.Fatalf("birleşme sonrası tek kayıt: %d", len(list))
	}
	if g := list[0]; !g.HasOfficialInvoice || g.DocumentNo == nil || *g.DocumentNo != testETTN1 || g.Amount != 212.5 || g.ID != pre.ID {
		t.Fatalf("birleşen kayıt: %+v", g)
	}

	// 4) Aynı resmi fatura yeniden ya da üçüncü bir belge: kayıt değişmez, hata fırlatılmaz (200 duplicate).
	// Aynı resmi mail yeniden (sağlayıcı yeniden denemesi): aynı client_uid hedefe çözülür → idempotent `merged`, yeni kayıt yok.
	st, out = e.mail(u, map[string]any{"text": officialInvoiceText})
	if st != 200 || out["status"] != "merged" {
		t.Fatalf("resmi mail tekrarı: %d %v", st, out)
	}
	third := strings.Replace(officialInvoiceText, "3f2a9c1e-5b7d-4e8a-9c3d-1a2b3c4d5e6f", testETTN2, 1)
	st, out = e.mail(u, map[string]any{"text": third})
	if st != 200 || out["status"] != "duplicate" {
		t.Fatalf("üçüncü belge: %d %v", st, out)
	}
	if n := len(e.list(u, "")); n != 1 {
		t.Fatalf("kayıt sayısı: %d", n)
	}
}

func TestPGInboundSameDayDifferentOrdersStaySeparate(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	lunch := strings.Replace(digital.HTMLToText(yemeksepetiHTML), "YS-4F7A91C2", "YS-LUNCH01", 1)
	dinner := strings.Replace(digital.HTMLToText(yemeksepetiHTML), "YS-4F7A91C2", "YS-DINNER2", 1)
	for _, txt := range []string{lunch, dinner} {
		if st, out := e.mail(u, map[string]any{"text": txt}); st != 200 || out["status"] != "created" {
			t.Fatalf("%d %v", st, out)
		}
	}
	if n := len(e.list(u, "")); n != 2 {
		t.Fatalf("aynı gün iki sipariş ayrı kalmalı: %d", n)
	}
}

func TestPGInboundRecipientResolution(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	addr := e.inboundAddress(u).Address
	local := strings.TrimSuffix(addr, "@"+testInboundDomain)

	cases := map[string]map[string]any{
		"büyük harf + tag":               {"to": strings.ToUpper(local) + "+fatura@" + testInboundDomain},
		"zarf (envelope)":                {"envelope": map[string]any{"to": []string{"baska@x.com", addr}}},
		"recipient":                      {"recipient": addr},
		"ham MIME X-Original-To":         {"raw": "From: a@b.com\nTo: ahmet@gmail.com\nX-Original-To: " + addr + "\nSubject: Fiş\nContent-Type: text/plain\n\nMigros\nSüt 32,50\nToplam 32,50\n"},
		"ham MIME Delivered-To (base64)": {"raw_base64": base64.StdEncoding.EncodeToString([]byte("From: a@b.com\nTo: ahmet@gmail.com\nDelivered-To: " + addr + "\nSubject: Fiş2\nContent-Type: text/plain\n\nBim\nEkmek 5,00\nToplam 5,00\n"))},
	}
	i := 0
	for name, c := range cases {
		i++
		payload := map[string]any{"text": "Market " + strings.Repeat("A", i) + "\nSipariş No: RR-" + strings.Repeat("7", i+3) + "\nToplam " + "1" + strings.Repeat("0", i) + ",00 TL"}
		for k, v := range c {
			payload[k] = v
		}
		if _, hasRaw := c["raw"]; hasRaw {
			delete(payload, "text")
		}
		if _, hasRaw := c["raw_base64"]; hasRaw {
			delete(payload, "text")
		}
		st, out := e.hook(testWebhookSecret, payload)
		if st != 200 || (out["status"] != "created" && out["status"] != "duplicate") {
			t.Errorf("%s: %d %v", name, st, out)
		}
	}
	if n := len(e.list(u, "")); n != len(cases) {
		t.Fatalf("her alıcı biçimi bir kayıt üretmeli: %d != %d", n, len(cases))
	}
	// Başka alan adındaki adres alias sayılmaz.
	st, out := e.hook(testWebhookSecret, map[string]any{"to": local + "@baska.com", "text": "Market\nToplam 10,00"})
	if st != 200 || out["status"] != "ignored" {
		t.Fatalf("yabancı alan adı: %d %v", st, out)
	}
}

func TestPGInboundTargetProfileAndTwoUsers(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const alice, bob = int64(1), int64(2)
	own := e.newProfile(alice, "İş")
	code, b := e.as(alice, "PUT", "/inbound-address", map[string]any{"profile_id": own.ID})
	e.want(code, 200, b, "profil")
	if st, out := e.mail(alice, map[string]any{"html": yemeksepetiHTML}); st != 200 || out["status"] != "created" {
		t.Fatalf("%d %v", st, out)
	}
	got := e.list(alice, "")
	if len(got) != 1 || got[0].ProfileID != own.ID {
		t.Fatalf("fiş seçilen profile düşmeli: %+v", got)
	}
	// Aynı mail Bob'un adresine gelirse Bob'un hesabına yazılır; Alice'in kaydı mükerrer sayılmaz.
	if st, out := e.mail(bob, map[string]any{"html": yemeksepetiHTML}); st != 200 || out["status"] != "created" {
		t.Fatalf("bob: %d %v", st, out)
	}
	if len(e.list(bob, "")) != 1 || len(e.list(alice, "")) != 1 {
		t.Fatal("hesaplar izole olmalı")
	}
}

func TestPGInboundGmailConfirmationIsNotAReceipt(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	body := "ahmet@gmail.com adresi bu adrese posta yönlendirmek istiyor.\nOnay kodu: 123456789\n" +
		"Onaylamak için tıklayın: https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-abc\nToplam 1,00"
	st, out := e.mail(u, map[string]any{"from": "Gmail Team <forwarding-noreply@google.com>", "subject": "Gmail Yönlendirme Onayı", "text": body})
	if st != 200 || out["status"] != "confirmation" {
		t.Fatalf("%d %v", st, out)
	}
	if n := len(e.list(u, "")); n != 0 {
		t.Fatalf("onay maili fiş olmamalı: %d", n)
	}
	code, b := e.as(u, "GET", "/inbound-address/confirmation", nil)
	e.want(code, 200, b, "confirmation")
	var c struct {
		Code string `json:"code"`
		Link string `json:"link"`
	}
	_ = json.Unmarshal(b, &c)
	if c.Code != "123456789" || c.Link != "https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-abc" {
		t.Fatalf("onay: %s", b)
	}
	// Başka gönderen aynı metni yollarsa onay sayılmaz (sahte onay).
	st, out = e.mail(u, map[string]any{"from": "evil@example.com", "text": body})
	if st != 200 || out["status"] == "confirmation" {
		t.Fatalf("sahte onay: %d %v", st, out)
	}
	// Güvenilmeyen bağlantı ana makinesi saklanmaz; kod yine sunulur.
	evil := "Onay kodu: 987654321\nhttps://mail-settings.google.com.evil.io/mail/vf-abc"
	st, out = e.mail(u, map[string]any{"from": "forwarding-noreply@google.com", "text": evil})
	if st != 200 || out["status"] != "confirmation" {
		t.Fatalf("%d %v", st, out)
	}
	code, b = e.as(u, "GET", "/inbound-address/confirmation", nil)
	e.want(code, 200, b, "confirmation 2")
	c.Code, c.Link = "", ""
	_ = json.Unmarshal(b, &c)
	if c.Code != "987654321" || c.Link != "" {
		t.Fatalf("güvenilmeyen bağlantı atılmalı: %s", b)
	}
	// 24 saatten eski onay sunulmaz.
	if _, err := e.db.Exec(`UPDATE expense.forwarding_confirmations SET received_at = now() - interval '25 hours' WHERE user_id = $1`, u); err != nil {
		t.Fatal(err)
	}
	code, b = e.as(u, "GET", "/inbound-address/confirmation", nil)
	e.want(code, 204, b, "süresi dolmuş onay")
}

func TestPGInboundPDFAttachment(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const u = int64(1)
	pdf := base64.StdEncoding.EncodeToString([]byte("%PDF-1.4 fake"))
	attach := []map[string]any{{"filename": "fatura.pdf", "content_type": "application/pdf", "content_base64": pdf}}

	// Metin katmanlı PDF: HTML gövdeden önce gelir, motor "pdf".
	e.h.inbound.PDFText = func([]byte) ([]string, error) {
		return []string{officialInvoiceText + "\nKöşebaşı Döner Restoran fatura metin katmanı"}, nil
	}
	st, out := e.mail(u, map[string]any{"html": "<p>Faturanız ektedir.</p>", "attachments": attach})
	if st != 200 || out["status"] != "created" {
		t.Fatalf("pdf: %d %v", st, out)
	}
	got := e.list(u, "")
	if len(got) != 1 || got[0].OcrEngine == nil || *got[0].OcrEngine != "pdf" || got[0].DocumentNo == nil || !got[0].HasOfficialInvoice {
		t.Fatalf("pdf kaydı: %+v", got)
	}

	// Okunamayan PDF + gövde yok: hata değil, ignored: pdf_unreadable; fiş açılmaz.
	e.h.inbound.PDFText = func([]byte) ([]string, error) { return nil, digital.ErrPDFUnreadable }
	st, out = e.mail(u, map[string]any{"attachments": attach})
	if st != 200 || out["status"] != "ignored" || out["reason"] != digital.SourcePDFUnreadable {
		t.Fatalf("okunamayan pdf: %d %v", st, out)
	}
	// PDF okuyucu panik atsa bile (güvenilmeyen girdi) istek 500 olmaz: sarılı okuyucu hata döner.
	e.h.inbound.PDFText = func(b []byte) ([]string, error) { return digital.PDFPageTexts(b) }
	st, out = e.mail(u, map[string]any{"attachments": attach})
	if st != 200 || out["status"] != "ignored" {
		t.Fatalf("bozuk pdf: %d %v", st, out)
	}
	if n := len(e.list(u, "")); n != 1 {
		t.Fatalf("kayıt sayısı: %d", n)
	}
}

func TestPGInboundIgnoresUnparsableMail(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	for name, p := range map[string]map[string]any{
		"tutarsız":  {"text": "Merhaba, nasılsınız? Hiç rakam yok."},
		"boş":       {},
		"yalnız ek": {"attachments": []map[string]any{{"filename": "x.png", "content_type": "image/png", "content_base64": "AAAA"}}},
	} {
		st, out := e.mail(1, p)
		if st != 200 || out["status"] != "ignored" {
			t.Errorf("%s: %d %v", name, st, out)
		}
	}
	if n := len(e.list(1, "")); n != 0 {
		t.Fatalf("fiş açılmamalı: %d", n)
	}
}

func TestInboundAliasLimiter(t *testing.T) {
	var l aliasLimiter
	now := time.Now()
	for i := 0; i < aliasMaxPerHour; i++ {
		if !l.allow("a", now) {
			t.Fatalf("%d. istek reddedilmemeli", i)
		}
	}
	if l.allow("a", now) {
		t.Fatal("limit aşıldı")
	}
	if !l.allow("b", now) {
		t.Fatal("başka alias etkilenmemeli")
	}
	if !l.allow("a", now.Add(61*time.Minute)) {
		t.Fatal("bir saat sonra yeniden izin verilmeli")
	}
}

func TestNewAliasIsUnguessable(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		a := newAlias()
		if len(a) != 16 || a != strings.ToLower(a) || seen[a] {
			t.Fatalf("alias: %q", a)
		}
		seen[a] = true
	}
}

func TestCheckProductionSecretsInbound(t *testing.T) {
	base := map[string]string{
		"APP_ENV": "production", "JWT_ACCESS_SECRET": strings.Repeat("k", 40), "INTERNAL_TOKEN": strings.Repeat("t", 30),
		"DATABASE_URL": "postgres://u:" + strings.Repeat("p", 20) + "@db/x",
	}
	get := func(extra map[string]string) func(string) string {
		return func(k string) string {
			if v, ok := extra[k]; ok {
				return v
			}
			return base[k]
		}
	}
	if err := checkProductionSecrets(get(nil)); err != nil {
		t.Fatalf("özellik kapalıyken sır gerekmez: %v", err)
	}
	var err error
	if err = checkProductionSecrets(get(map[string]string{"INBOUND_EMAIL_DOMAIN": "fis.example.com", "INBOUND_WEBHOOK_SECRET": "short"})); err == nil {
		t.Fatal("zayıf webhook secret reddedilmeli")
	}
	if err = checkProductionSecrets(get(map[string]string{"INBOUND_EMAIL_DOMAIN": "fis.example.com", "INBOUND_WEBHOOK_SECRET": strings.Repeat("s", 32)})); err != nil {
		t.Fatalf("güçlü secret kabul edilmeli: %v", errors.Unwrap(err))
	}
}
