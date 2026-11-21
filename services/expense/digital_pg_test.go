package main

import (
	"encoding/json"
	"strconv"
	"testing"
)

func itoa(id int64) string { return strconv.FormatInt(id, 10) }

// Dijital fiş: order_id / has_official_invoice, mükerrer reddi ve ön özet + resmi fatura birleştirme (gerçek Postgres).
// YIKICIDIR: bkz. isolation_pg_test.go. Karar mantığının kendisi internal/digital'de (ortak golden vektörleri) sınanır;
// burada DB entegrasyonu ve kural A/B/C'nin uçtan uca davranışı doğrulanır.

const (
	testETTN1 = "3f2a9c1e-5b7d-4e8a-9c3d-1a2b3c4d5e6f"
	testETTN2 = "11111111-2222-4333-8444-555555555555"
	testETTN3 = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
)

func (e *xenv) post(uid int64, body map[string]any) (int, expenseOut, []byte) {
	e.t.Helper()
	code, b := e.as(uid, "POST", "/expenses", body)
	var out expenseOut
	_ = json.Unmarshal(b, &out)
	return code, out, b
}

func (e *xenv) bulk(uid int64, items ...map[string]any) bulkResp {
	e.t.Helper()
	code, b := e.as(uid, "POST", "/expenses/bulk", map[string]any{"expenses": items})
	e.want(code, 200, b, "bulk")
	var out bulkResp
	if err := json.Unmarshal(b, &out); err != nil {
		e.t.Fatal(err)
	}
	return out
}

func errCode(b []byte) string {
	var m struct {
		Code string `json:"code"`
	}
	_ = json.Unmarshal(b, &m)
	return m.Code
}

func TestPGMigrateIsIdempotentWithDigitalColumns(t *testing.T) {
	e := newXEnv(t)
	if err := migrate(e.db); err != nil {
		t.Fatalf("ikinci migrate: %v", err)
	}
	var generated string
	if err := e.db.QueryRow(`SELECT is_generated FROM information_schema.columns WHERE table_schema='expense' AND table_name='expenses' AND column_name='has_official_invoice'`).Scan(&generated); err != nil || generated != "ALWAYS" {
		t.Fatalf("has_official_invoice türetilmiş sütun olmalı: %q %v", generated, err)
	}
}

func TestPGPreSummaryThenOfficialInvoiceMerges(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	p := e.profiles(u)[0]

	// Ön özet (HTML sipariş özeti): order_id var, document_no yok.
	pre := e.create(u, e.exp("Yemeksepeti", 210, p.ID, map[string]any{"date": "2026-11-14", "order_id": "ys-4f7a91c2", "client_uid": "pre-1",
		"items": []any{map[string]any{"name": "Tavuk Döner Porsiyon", "amount": 185}, map[string]any{"name": "Ayran", "amount": 25}}}))
	if pre.OrderID == nil || *pre.OrderID != "YS-4F7A91C2" || pre.HasOfficialInvoice || pre.DocumentNo != nil {
		t.Fatalf("ön özet: %+v", pre)
	}

	// A: aynı sipariş + aynı tür (ön özet) → 409 duplicate_order.
	code, _, b := e.post(u, e.exp("Yemeksepeti", 210, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-4F7A91C2", "client_uid": "pre-2"}))
	if code != 409 || errCode(b) != "duplicate_order" {
		t.Fatalf("aynı sipariş ön özeti: %d %s", code, b)
	}
	// Aynı client_uid tekrarı hâlâ idempotent (200, aynı id).
	code, again, b := e.post(u, e.exp("Yemeksepeti", 210, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-4F7A91C2", "client_uid": "pre-1"}))
	if code != 200 || again.ID != pre.ID {
		t.Fatalf("idempotent tekrar: %d %s", code, b)
	}

	// B: resmi fatura aynı order_id ile gelir → yeni kayıt YOK, ön özet güncellenir ve kilitlenir.
	code, merged, b := e.post(u, e.exp("Köşebaşı Döner Ltd. Şti.", 212.5, p.ID, map[string]any{"date": "2026-11-17", "order_id": "YS-4F7A91C2",
		"document_no": testETTN1, "client_uid": "off-1", "ocr_engine": "pdf"}))
	if code != 200 || merged.Status != "merged" || merged.ID != pre.ID {
		t.Fatalf("birleştirme: %d %s", code, b)
	}
	if !merged.HasOfficialInvoice || merged.DocumentNo == nil || *merged.DocumentNo != testETTN1 || merged.Amount != 212.5 {
		t.Fatalf("birleşen kayıt: %+v", merged)
	}
	if merged.Merchant != "Yemeksepeti" || merged.Date != "2026-11-14" || len(merged.Items) != 2 {
		t.Fatalf("kullanıcı alanları ezilmemeli (işletme/tarih/kalemler): %+v", merged)
	}
	if merged.OcrEngine == nil || *merged.OcrEngine != "pdf" {
		t.Fatalf("boş ocr_engine doldurulmalı: %+v", merged.OcrEngine)
	}
	if n := len(e.list(u, "")); n != 1 {
		t.Fatalf("tek kayıt kalmalı, %d var", n)
	}

	// Kilit: üçüncü bir resmi belge (başka ETTN, aynı sipariş) üzerine yazamaz / yeni kayıt açamaz.
	code, _, b = e.post(u, e.exp("Köşebaşı", 212.5, p.ID, map[string]any{"date": "2026-11-17", "order_id": "YS-4F7A91C2", "document_no": testETTN2, "client_uid": "off-2"}))
	if code != 409 || errCode(b) != "duplicate_order" {
		t.Fatalf("üçüncü belge (aynı sipariş): %d %s", code, b)
	}
	// Aynı ETTN yeniden → duplicate_document.
	code, _, b = e.post(u, e.exp("Köşebaşı", 212.5, p.ID, map[string]any{"date": "2026-11-17", "document_no": testETTN1, "client_uid": "off-3"}))
	if code != 409 || errCode(b) != "duplicate_document" {
		t.Fatalf("aynı ETTN: %d %s", code, b)
	}
	// Resmi kayıt varken aynı siparişin ön özeti de reddedilir (resmi belge zaten kapsıyor).
	code, _, b = e.post(u, e.exp("Yemeksepeti", 210, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-4F7A91C2", "client_uid": "pre-3"}))
	if code != 409 || errCode(b) != "duplicate_order" {
		t.Fatalf("resmi varken ön özet: %d %s", code, b)
	}

	// PUT: order_id/document_no atlayan düzenleme mevcut değerleri korur; has_official_invoice geri alınamaz.
	code, b = e.as(u, "PUT", "/expenses/"+itoa(pre.ID), e.exp("Yemeksepeti", 212.5, p.ID, map[string]any{"date": "2026-11-14", "note": "düzenlendi"}))
	e.want(code, 200, b, "put")
	got := decodeExpense(t, b)
	if got.DocumentNo == nil || got.OrderID == nil || !got.HasOfficialInvoice {
		t.Fatalf("PUT sonrası kimlikler korunmalı: %+v", got)
	}
	// has_official_invoice istekte gönderilse bile yok sayılır.
	code, b = e.as(u, "PUT", "/expenses/"+itoa(pre.ID), e.exp("Yemeksepeti", 212.5, p.ID, map[string]any{"date": "2026-11-14", "has_official_invoice": false}))
	e.want(code, 200, b, "put has_official_invoice")
	if !decodeExpense(t, b).HasOfficialInvoice {
		t.Fatal("has_official_invoice istemciden kapatılamaz")
	}
}

func TestPGInvalidOrderIDAndAccountIsolation(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	pa, pb := e.profiles(alice)[0], e.profiles(bob)[0]
	for _, bad := range []string{"ab", "-abc1", "has space 1", "x/y/z/1"} {
		code, _, b := e.post(alice, e.exp("X", 10, pa.ID, map[string]any{"order_id": bad}))
		if code != 400 {
			t.Errorf("order_id %q: %d %s", bad, code, b)
		}
	}
	e.create(alice, e.exp("A", 10, pa.ID, map[string]any{"order_id": "ORD-1001"}))
	// Başka hesapta aynı sipariş kodu çakışmaz.
	e.create(bob, e.exp("A", 10, pb.ID, map[string]any{"order_id": "ORD-1001"}))
	// Kuralın yalnız document_no/order_id taşıyan fişleri etkilediğinden emin ol: numarasız fişler hep eklenir.
	e.create(alice, e.exp("Migros", 10, pa.ID, map[string]any{"client_uid": "n1"}))
	e.create(alice, e.exp("Migros", 10, pa.ID, map[string]any{"client_uid": "n2"}))
}

func TestPGSameDayTwoOrdersAreNeverMerged(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	p := e.profiles(u)[0]
	// Öğle ve akşam: aynı işletme, aynı tutar, aynı gün, farklı siparişler.
	a := e.create(u, e.exp("Köşebaşı Döner", 210, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-A111", "client_uid": "a"}))
	b := e.create(u, e.exp("Köşebaşı Döner", 210, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-B222", "client_uid": "b"}))

	// order_id'siz resmi fatura: iki aday → belirsiz → birleşmez, ayrı kayıt.
	code, off, body := e.post(u, e.exp("Köşebaşı Döner", 210, p.ID, map[string]any{"date": "2026-11-14", "document_no": testETTN1, "client_uid": "o1"}))
	if code != 201 || off.Status == "merged" || off.ID == a.ID || off.ID == b.ID {
		t.Fatalf("belirsiz durumda birleşmemeli: %d %s", code, body)
	}
	// order_id'li resmi fatura yalnızca KENDİ siparişine birleşir.
	code, off2, body := e.post(u, e.exp("Köşebaşı Döner Ltd", 210, p.ID, map[string]any{"date": "2026-11-14", "document_no": testETTN2, "order_id": "YS-B222", "client_uid": "o2"}))
	if code != 200 || off2.Status != "merged" || off2.ID != b.ID {
		t.Fatalf("order_id eşleşmesi: %d %s", code, body)
	}
	// Farklı order_id'li resmi fatura, tutar/gün aynı olsa da A'ya (YS-A111) birleşmez.
	code, off3, body := e.post(u, e.exp("Köşebaşı Döner", 210, p.ID, map[string]any{"date": "2026-11-14", "document_no": testETTN3, "order_id": "YS-C333", "client_uid": "o3"}))
	if code != 201 || off3.ID == a.ID {
		t.Fatalf("farklı sipariş birleşmemeli: %d %s", code, body)
	}
	// A hâlâ ön özet ve dokunulmamış.
	cur := decodeExpenseFromGet(t, e, u, a.ID)
	if cur.HasOfficialInvoice || cur.DocumentNo != nil {
		t.Fatalf("A değişmemeli: %+v", cur)
	}
}

func decodeExpenseFromGet(t *testing.T, e *xenv, uid, id int64) expenseOut {
	t.Helper()
	code, b := e.as(uid, "GET", "/expenses/"+itoa(id), nil)
	e.want(code, 200, b, "get")
	return decodeExpense(t, b)
}

func TestPGFuzzyMergeWithoutOrderID(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	p := e.profiles(u)[0]
	pre := e.create(u, e.exp("Köşebaşı Döner", 210, p.ID, map[string]any{"date": "2026-11-14", "client_uid": "p1",
		"items": []any{map[string]any{"name": "Tavuk Döner", "amount": 185}, map[string]any{"name": "Ayran", "amount": 25}}}))
	// Tutar farklı → birleşmez.
	code, other, b := e.post(u, e.exp("Köşebaşı Döner", 211, p.ID, map[string]any{"date": "2026-11-15", "document_no": testETTN2, "client_uid": "x"}))
	if code != 201 || other.ID == pre.ID {
		t.Fatalf("tutar farklı: %d %s", code, b)
	}
	// Tarih penceresi dışı → birleşmez.
	code, other, b = e.post(u, e.exp("Köşebaşı Döner", 210, p.ID, map[string]any{"date": "2026-11-20", "document_no": testETTN3, "client_uid": "y"}))
	if code != 201 || other.ID == pre.ID {
		t.Fatalf("pencere dışı: %d %s", code, b)
	}
	// Aynı işletme + tutar + ±3 gün + tek aday → birleşir.
	code, m, b := e.post(u, e.exp("KÖŞEBAŞI DÖNER", 210, p.ID, map[string]any{"date": "2026-11-16", "document_no": testETTN1, "client_uid": "z",
		"items": []any{map[string]any{"name": "TAVUK DONER", "amount": 185}, map[string]any{"name": "AYRAN", "amount": 25}}}))
	if code != 200 || m.Status != "merged" || m.ID != pre.ID || !m.HasOfficialInvoice {
		t.Fatalf("fuzzy birleştirme: %d %s", code, b)
	}
}

func TestPGBulkMergeAndDuplicates(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	p := e.profiles(u)[0]
	pre := e.exp("Yemeksepeti", 100, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-9001", "client_uid": "b-pre"})
	off := e.exp("Restoran Ltd", 104, p.ID, map[string]any{"date": "2026-11-16", "order_id": "YS-9001", "document_no": testETTN1, "client_uid": "b-off"})
	dupOrder := e.exp("Yemeksepeti", 100, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-9001", "client_uid": "b-dup"})
	plain := e.exp("BIM", 20, p.ID, map[string]any{"client_uid": "b-plain"})

	r := e.bulk(u, pre, off, dupOrder, plain)
	if r.Created != 2 || r.Merged != 1 || r.Failed != 1 || r.Skipped != 0 {
		t.Fatalf("bulk sayaçları: %+v", r)
	}
	if r.Results[0].Status != "created" || r.Results[1].Status != "merged" || r.Results[1].ID != r.Results[0].ID {
		t.Fatalf("bulk sonuçları: %+v", r.Results)
	}
	// ön özet + resmi → sıra içinde: dupOrder resmi varken gelen ön özet → duplicate_order
	if r.Results[2].Status != "error" || r.Results[2].Error != "duplicate_order" || r.Results[3].Status != "created" {
		t.Fatalf("bulk mükerrer: %+v", r.Results)
	}
	if n := len(e.list(u, "")); n != 2 {
		t.Fatalf("2 kayıt beklenir: %d", n)
	}
	// Tekrar gönderim (yanıtı kaybolan istek / çevrimdışı kuyruk): ön özetin client_uid'si skipped; birleşen resmi belgenin client_uid'si
	// hedefte kayıtlıdır → AYNI hedefe `merged` olarak çözülür (hata değil, yeni kayıt değil, ikinci güncelleme değil).
	r2 := e.bulk(u, pre, off)
	if r2.Results[0].Status != "skipped" || r2.Results[1].Status != "merged" || r2.Results[1].ID != r.Results[0].ID || r2.Merged != 1 || r2.Failed != 0 {
		t.Fatalf("bulk tekrar: %+v", r2)
	}
	if n := len(e.list(u, "")); n != 2 {
		t.Fatalf("tekrar kayıt açmamalı: %d", n)
	}
}

func TestPGMergeReplayIsIdempotentOnPost(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	p := e.profiles(u)[0]
	pre := e.create(u, e.exp("Yemeksepeti", 210, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-RP1", "client_uid": "pre"}))
	body := e.exp("Restoran", 212.5, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-RP1", "document_no": testETTN1, "client_uid": "off"})
	code, first, b := e.post(u, body)
	if code != 200 || first.Status != "merged" || first.ID != pre.ID {
		t.Fatalf("ilk istek: %d %s", code, b)
	}
	// Yanıt kaybolmuştu: aynı istek yeniden gelir → aynı hedef, hata yok, ikinci güncelleme yok.
	code, again, b := e.post(u, body)
	if code != 200 || again.Status != "merged" || again.ID != pre.ID || again.UpdatedAt != first.UpdatedAt {
		t.Fatalf("tekrar: %d %s (updated_at %s != %s)", code, b, again.UpdatedAt, first.UpdatedAt)
	}
	// Başka bir client_uid'li aynı belge ise hâlâ mükerrerdir.
	code, _, b = e.post(u, e.exp("Restoran", 212.5, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-RP1", "document_no": testETTN1, "client_uid": "other"}))
	if code != 409 {
		t.Fatalf("farklı client_uid aynı belge: %d %s", code, b)
	}
}

func TestPGPutCannotOverwriteBoundDocument(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	p := e.profiles(u)[0]
	pre := e.create(u, e.exp("Yemeksepeti", 210, p.ID, map[string]any{"date": "2026-11-14", "order_id": "YS-LK1", "client_uid": "pre"}))
	put := func(extra map[string]any) (int, []byte) {
		return e.as(u, "PUT", "/expenses/"+itoa(pre.ID), e.exp("Yemeksepeti", 210, p.ID, extra))
	}
	// Belge ilk kez bağlanır (özet → resmi): serbest.
	code, b := put(map[string]any{"document_no": testETTN1})
	e.want(code, 200, b, "ilk bağlama")
	// Aynı belge numarası yeniden (düzenleme): serbest; alanı atlamak da.
	code, b = put(map[string]any{"document_no": testETTN1, "note": "n"})
	e.want(code, 200, b, "aynı belge")
	code, b = put(map[string]any{"note": "m"})
	e.want(code, 200, b, "belge atlandı")
	// Farklı belge: kilitli kayıt üzerine yazılamaz (bayat önbellekten gelen "birleştirme" PUT'u dahil).
	code, b = put(map[string]any{"document_no": testETTN2})
	if code != 409 || errCode(b) != "document_locked" {
		t.Fatalf("farklı belge: %d %s", code, b)
	}
	if got := decodeExpenseFromGet(t, e, u, pre.ID); got.DocumentNo == nil || *got.DocumentNo != testETTN1 {
		t.Fatalf("belge değişmemeli: %+v", got.DocumentNo)
	}
}

func TestPGOrderPurgeAndOwnership(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	// Bob'un resmi belgesi Alice'in ön özetine asla birleşmez (aday sorgusu hesaba kapsamlı).
	pa, pb := e.profiles(alice)[0], e.profiles(bob)[0]
	pre := e.create(alice, e.exp("Köşebaşı", 50, pa.ID, map[string]any{"order_id": "ZZ-1234", "date": "2026-11-10"}))
	code, off, b := e.post(bob, e.exp("Köşebaşı", 50, pb.ID, map[string]any{"order_id": "ZZ-1234", "document_no": testETTN1, "date": "2026-11-10"}))
	if code != 201 || off.ID == pre.ID {
		t.Fatalf("hesaplar arası birleşme olmamalı: %d %s", code, b)
	}
}
