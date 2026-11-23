package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
)

// Profil kuralları (8 sınır, Türkçe katlamalı benzersiz ad), profil bazlı e-posta adresi/geçmiş/onay, eski şemadan
// idempotent geçiş ve başarısız aktarım bildirimi. Gerçek Postgres; YIKICIDIR (bkz. isolation_pg_test.go).

func (e *xenv) postProfile(uid int64, body map[string]any) (int, map[string]any) {
	e.t.Helper()
	code, b := e.as(uid, "POST", "/profiles", body)
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	return code, out
}

func TestPGProfileLimitAndUniqueNames(t *testing.T) {
	e := newXEnv(t)
	const u = int64(1)
	if n := len(e.profiles(u)); n != 1 { // varsayılan "Kişisel"
		t.Fatalf("varsayılan profil: %d", n)
	}
	for i := 2; i <= maxProfilesPerUser; i++ {
		e.newProfile(u, fmt.Sprintf("Profil %d", i))
	}
	code, out := e.postProfile(u, map[string]any{"name": "Dokuzuncu"})
	if code != 409 || out["code"] != codeProfileLimit {
		t.Fatalf("9. profil reddedilmeli: %d %v", code, out)
	}
	// Idempotent client_uid tekrarı sınırda da 200 döner (çevrimdışı kuyruk tekrarı hata olmamalı).
	last := e.profiles(u)[maxProfilesPerUser-1]
	if code, out := e.postProfile(u, map[string]any{"name": "Başka", "client_uid": last.ClientUID}); code != 200 {
		t.Fatalf("idempotent tekrar: %d %v", code, out)
	}

	const v = int64(2)
	e.profiles(v) // varsayılan "Kişisel"
	ist := e.newProfile(v, "İstanbul")
	for _, dup := range []string{"istanbul", "  ISTANBUL ", "İSTANBUL", "Kişisel", "kisisel"} {
		if code, out := e.postProfile(v, map[string]any{"name": dup}); code != 409 || out["code"] != codeDuplicateProfileName {
			t.Fatalf("aynı ad %q reddedilmeli: %d %v", dup, code, out)
		}
	}
	ev := e.newProfile(v, "Ev")
	code, b := e.as(v, "PUT", fmt.Sprintf("/profiles/%d", ev.ID), map[string]any{"name": "istanbul"})
	if code != 409 || !strings.Contains(string(b), codeDuplicateProfileName) {
		t.Fatalf("başka profilin adına rename reddedilmeli: %d %s", code, b)
	}
	code, b = e.as(v, "PUT", fmt.Sprintf("/profiles/%d", ist.ID), map[string]any{"name": "İSTANBUL"})
	e.want(code, 200, b, "kendi adını harf değiştirerek rename")
	code, b = e.as(v, "PUT", "/profiles/999999", map[string]any{"name": "Yok"})
	if code != 404 || !strings.Contains(string(b), codeProfileNotFound) {
		t.Fatalf("olmayan profil: %d %s", code, b)
	}
	// Başka kullanıcının aynı adlı profili engel değildir.
	e.newProfile(u+10, "İstanbul")
}

func TestProfileNameKey(t *testing.T) {
	cases := map[string]string{"İstanbul": "istanbul", "  ISTANBUL  ": "istanbul", "Ev   İş": "ev is", "Kişisel": "kisisel"}
	for in, want := range cases {
		if got := profileNameKey(in); got != want {
			t.Errorf("profileNameKey(%q)=%q want %q", in, got, want)
		}
	}
}

func TestPGInboundPerProfile(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	const alice, bob = int64(1), int64(2)
	def := e.profiles(alice)[0]
	work := e.newProfile(alice, "İş")
	defAddr := e.inboundAddress(alice)
	workAddr := e.inboundAddressFor(alice, work.ClientUID)
	if defAddr.Address == workAddr.Address {
		t.Fatal("her profilin kendi adresi olmalı")
	}

	// İş adresine gelen fiş İş profiline, varsayılan adrese gelen varsayılana yazılır.
	if st, out := e.hook(testWebhookSecret, map[string]any{"to": workAddr.Address, "from": "a@b.c", "subject": "Sipariş", "html": yemeksepetiHTML}); st != 200 || out["status"] != "created" {
		t.Fatalf("iş: %d %v", st, out)
	}
	if st, out := e.hook(testWebhookSecret, map[string]any{"to": defAddr.Address, "from": "a@b.c", "subject": "Merhaba", "text": "Merhaba, nasılsın?"}); st != 200 || out["status"] != "ignored" {
		t.Fatalf("varsayılan: %d %v", st, out)
	}
	got := e.list(alice, "")
	if len(got) != 1 || got[0].ProfileID != work.ID {
		t.Fatalf("fiş alias'ın profiline düşmeli: %+v", got)
	}
	// Geçmiş ve son durum profil bazlı.
	if h := e.history(alice, "?profile_uid="+work.ClientUID); len(h.Items) != 1 || h.Items[0].Status != "saved" {
		t.Fatalf("iş geçmişi: %+v", h.Items)
	}
	if h := e.history(alice, ""); len(h.Items) != 1 || h.Items[0].Status != "ignored" {
		t.Fatalf("varsayılan geçmişi: %+v", h.Items)
	}
	if a := e.inboundAddressFor(alice, work.ClientUID); a.LastStatus == nil || *a.LastStatus != "created" {
		t.Fatalf("iş last_status: %+v", a)
	}
	if a := e.inboundAddress(alice); a.LastStatus == nil || !strings.HasPrefix(*a.LastStatus, "ignored:") {
		t.Fatalf("varsayılan last_status: %+v", a)
	}

	// Gmail onayı yalnız ilgili profilde görünür.
	conf := "Onay kodu: 123456789\nhttps://mail-settings.google.com/mail/vf-%5BX%5D-abc"
	if st, out := e.hook(testWebhookSecret, map[string]any{"to": workAddr.Address, "from": "Gmail Team <forwarding-noreply@google.com>", "text": conf}); st != 200 || out["status"] != "confirmation" {
		t.Fatalf("onay: %d %v", st, out)
	}
	code, b := e.as(alice, "GET", "/inbound-address/confirmation?profile_uid="+work.ClientUID, nil)
	e.want(code, 200, b, "iş onayı")
	code, b = e.as(alice, "GET", "/inbound-address/confirmation", nil)
	e.want(code, 204, b, "varsayılanda onay yok")

	// Duraklatma profil bazlı.
	code, b = e.as(alice, "POST", "/inbound-address/pause?profile_uid="+work.ClientUID, nil)
	e.want(code, 200, b, "pause iş")
	if a := e.inboundAddress(alice); a.Paused {
		t.Fatal("varsayılan profil duraklamamalı")
	}
	// Rotate yalnız iş profilinin onaylarını siler.
	if _, err := e.db.Exec(`INSERT INTO expense.forwarding_confirmations (user_id, profile_id, code) VALUES ($1, $2, '111222333')`, alice, def.ID); err != nil {
		t.Fatal(err)
	}
	code, b = e.as(alice, "POST", "/inbound-address/rotate?profile_uid="+work.ClientUID, nil)
	e.want(code, 200, b, "rotate iş")
	code, b = e.as(alice, "GET", "/inbound-address/confirmation", nil)
	e.want(code, 200, b, "varsayılanın onayı kalır")

	// Bob, Alice'in profil uid'siyle erişemez; kendi adresine gelen aynı mail Bob'a yazılır.
	code, b = e.as(bob, "GET", "/inbound-address/history?profile_uid="+work.ClientUID, nil)
	e.want(code, 404, b, "başkasının profil geçmişi")
	if st, out := e.mail(bob, map[string]any{"html": yemeksepetiHTML}); st != 200 || out["status"] != "created" {
		t.Fatalf("bob: %d %v", st, out)
	}
	if len(e.list(bob, "")) != 1 || len(e.list(alice, "")) != 1 {
		t.Fatal("hesaplar izole olmalı")
	}

	// Profil silinince adresi (CASCADE) ve geçmişi gider; eski adrese gelen mail bilinmeyen alias olur (500 değil).
	newWork := e.inboundAddressFor(alice, work.ClientUID)
	code, b = e.as(alice, "DELETE", fmt.Sprintf("/profiles/%d", work.ID), nil)
	e.want(code, 204, b, "profil sil")
	if st, out := e.hook(testWebhookSecret, map[string]any{"to": newWork.Address, "html": yemeksepetiHTML}); st != 200 || out["reason"] != "unknown_alias" {
		t.Fatalf("silinen profilin adresi: %d %v", st, out)
	}
	for _, table := range []string{"inbound_aliases", "inbound_history", "forwarding_confirmations"} {
		var n int
		if err := e.db.QueryRow(`SELECT count(*) FROM expense.`+table+` WHERE profile_id = $1`, work.ID).Scan(&n); err != nil || n != 0 {
			t.Fatalf("%s: n=%d err=%v", table, n, err)
		}
	}
}

// Eski şema (kullanıcı başına tek alias, profile_id NULL olabilir; onay/geçmişte profile_id yok) yerinde dönüşür ve
// migrate iki kez çalıştırılabilir.
func TestPGInboundMigrationLegacy(t *testing.T) {
	e := newXEnv(t)
	const u1, u2, u3, u4 = int64(1), int64(2), int64(3), int64(4)
	p1 := e.profiles(u1)[0]
	e.profiles(u2)
	p2 := e.newProfile(u2, "İş")
	mustExec := func(q string, args ...any) {
		t.Helper()
		if _, err := e.db.Exec(q, args...); err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
	}
	mustExec(`DROP TABLE expense.inbound_history, expense.forwarding_confirmations, expense.inbound_aliases, expense.inbound_settings`)
	mustExec(`
CREATE TABLE expense.inbound_aliases (
	user_id          BIGINT PRIMARY KEY,
	alias            TEXT NOT NULL UNIQUE,
	profile_id       BIGINT REFERENCES expense.profiles(id) ON DELETE SET NULL,
	created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
	last_received_at TIMESTAMPTZ,
	last_status      TEXT
);
ALTER TABLE expense.inbound_aliases ADD COLUMN IF NOT EXISTS paused BOOLEAN NOT NULL DEFAULT false;
CREATE TABLE expense.forwarding_confirmations (
	id          BIGSERIAL PRIMARY KEY,
	user_id     BIGINT NOT NULL,
	code        TEXT NOT NULL,
	link        TEXT,
	received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE expense.inbound_history (
	id          BIGSERIAL PRIMARY KEY,
	user_id     BIGINT NOT NULL,
	received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
	source      TEXT NOT NULL DEFAULT 'email',
	from_addr   TEXT,
	subject     TEXT,
	status      TEXT NOT NULL CHECK (status IN ('saved', 'ignored', 'failed')),
	reason      TEXT,
	expense_id  BIGINT REFERENCES expense.expenses(id) ON DELETE SET NULL
);`)
	mustExec(`INSERT INTO expense.inbound_aliases (user_id, alias, profile_id, last_status) VALUES
		(1, 'legacyaliasuser1', NULL, 'created'), (2, 'legacyaliasuser2', $1, NULL), (3, 'legacyaliasuser3', NULL, NULL)`, p2.ID)
	mustExec(`INSERT INTO expense.forwarding_confirmations (user_id, code) VALUES (1, '111'), (3, '333'), (4, '444')`)
	mustExec(`INSERT INTO expense.inbound_history (user_id, status, reason) VALUES (1, 'saved', 'created'), (2, 'ignored', 'no_amount'), (4, 'ignored', 'x')`)

	for i := 0; i < 2; i++ {
		if err := migrate(e.db); err != nil {
			t.Fatalf("migrate #%d: %v", i+1, err)
		}
	}

	aliasProfile := func(uid int64) int64 {
		t.Helper()
		var pid int64
		if err := e.db.QueryRow(`SELECT profile_id FROM expense.inbound_aliases WHERE user_id = $1`, uid).Scan(&pid); err != nil {
			t.Fatal(err)
		}
		return pid
	}
	if got := aliasProfile(u1); got != p1.ID {
		t.Fatalf("u1 NULL -> varsayılan profil: %d want %d", got, p1.ID)
	}
	if got := aliasProfile(u2); got != p2.ID {
		t.Fatalf("u2 seçili profil korunur: %d want %d", got, p2.ID)
	}
	var u3Profile int64
	if err := e.db.QueryRow(`SELECT id FROM expense.profiles WHERE user_id = 3 AND client_uid = 'srv-default-3'`).Scan(&u3Profile); err != nil {
		t.Fatalf("profilsiz alias sahibine varsayılan profil: %v", err)
	}
	if got := aliasProfile(u3); got != u3Profile {
		t.Fatalf("u3: %d want %d", got, u3Profile)
	}
	var n int
	_ = e.db.QueryRow(`SELECT count(*) FROM expense.forwarding_confirmations WHERE user_id = 4`).Scan(&n)
	if n != 0 {
		t.Fatal("eşleşmeyen onay silinmeli")
	}
	_ = e.db.QueryRow(`SELECT count(*) FROM expense.inbound_history WHERE user_id = 4`).Scan(&n)
	if n != 0 {
		t.Fatal("profilsiz kullanıcının geçmişi silinmeli")
	}
	var hp int64
	if err := e.db.QueryRow(`SELECT profile_id FROM expense.inbound_history WHERE user_id = 2`).Scan(&hp); err != nil || hp != p2.ID {
		t.Fatalf("u2 geçmişi alias profiline: %d %v", hp, err)
	}
	var pkCols int
	if err := e.db.QueryRow(`SELECT array_length(conkey, 1) FROM pg_constraint
		WHERE conrelid = 'expense.inbound_aliases'::regclass AND contype = 'p'`).Scan(&pkCols); err != nil || pkCols != 2 {
		t.Fatalf("bileşik PK: %d %v", pkCols, err)
	}
	var nonCascade int
	if err := e.db.QueryRow(`SELECT count(*) FROM pg_constraint WHERE contype = 'f' AND confrelid = 'expense.profiles'::regclass
		AND confdeltype <> 'c' AND conrelid IN ('expense.inbound_aliases'::regclass, 'expense.forwarding_confirmations'::regclass,
		'expense.inbound_history'::regclass)`).Scan(&nonCascade); err != nil || nonCascade != 0 {
		t.Fatalf("FK'lar CASCADE olmalı: %d %v", nonCascade, err)
	}

	// Kurulu yönlendirme bozulmaz: eski adres aynı profile yazar; yeni profil yeni adres alır.
	e.enableInbound()
	if a := e.inboundAddressFor(u2, p2.ClientUID); a.Address != "legacyaliasuser2@"+testInboundDomain {
		t.Fatalf("eski adres korunmalı: %+v", a)
	}
	if a := e.inboundAddress(u1); a.Address != "legacyaliasuser1@"+testInboundDomain || a.LastStatus == nil {
		t.Fatalf("u1 adres/durum: %+v", a)
	}
	if a := e.inboundAddress(u2); a.Address == "legacyaliasuser2@"+testInboundDomain {
		t.Fatal("u2 varsayılan profiline yeni adres üretilmeli")
	}
	// Profil silme artık 500 değil (NOT NULL + CASCADE).
	code, b := e.as(u2, "DELETE", fmt.Sprintf("/profiles/%d", p2.ID), nil)
	e.want(code, 204, b, "profil sil")
}

// recNotifier eşzamanlı kayıt tutan sahte bildirimci.
type recNotifier struct {
	mu   sync.Mutex
	got  []failureNotice
	full bool
}

func (r *recNotifier) Enqueue(n failureNotice) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.full {
		return false
	}
	r.got = append(r.got, n)
	return true
}

func (r *recNotifier) list() []failureNotice {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]failureNotice(nil), r.got...)
}

func TestPGInboundFailureNotifications(t *testing.T) {
	e := newXEnv(t)
	e.enableInbound()
	rec := &recNotifier{}
	e.h.notifier = rec
	const alice, bob = int64(1), int64(2)
	noAmount := map[string]any{"subject": "Selam\x07" + strings.Repeat("ş", 300), "text": "Merhaba, nasılsın?"}

	if st, out := e.mail(alice, noAmount); st != 200 || out["reason"] != "no_amount" {
		t.Fatalf("%d %v", st, out)
	}
	got := rec.list()
	if len(got) != 1 {
		t.Fatalf("1 bildirim beklenir: %+v", got)
	}
	n := got[0]
	if n.UserID != alice || n.ProfileName != "Kişisel" || !strings.Contains(n.Reason, "tutar") || n.ReceivedAt.IsZero() ||
		strings.ContainsRune(n.MailSubject, '\x07') || len([]rune(n.MailSubject)) > failureNoticeSubjectMax+1 {
		t.Fatalf("bildirim içeriği: %+v", n)
	}

	// Başarılı, mükerrer ve Gmail onayı bildirim üretmez.
	for _, m := range []map[string]any{
		{"html": yemeksepetiHTML},
		{"html": yemeksepetiHTML},
		{"from": "Gmail Team <forwarding-noreply@google.com>", "text": "Onay kodu: 123456789"},
	} {
		e.mail(alice, m)
	}
	if len(rec.list()) != 1 {
		t.Fatalf("başarılı/mükerrer/onay bildirim üretmemeli: %+v", rec.list())
	}

	// Duraklatılmış adres bildirilir.
	code, b := e.as(alice, "POST", "/inbound-address/pause", nil)
	e.want(code, 200, b, "pause")
	e.mail(alice, map[string]any{"html": yemeksepetiHTML})
	if l := rec.list(); len(l) != 2 || !strings.Contains(l[1].Reason, "duraklat") {
		t.Fatalf("paused bildirimi: %+v", l)
	}
	code, b = e.as(alice, "POST", "/inbound-address/resume", nil)
	e.want(code, 200, b, "resume")

	// Tercih kapalıyken bildirim yok.
	code, b = e.as(alice, "GET", "/inbound-settings", nil)
	if code != 200 || !strings.Contains(string(b), `"notify_failures":true`) {
		t.Fatalf("varsayılan tercih: %d %s", code, b)
	}
	code, b = e.as(alice, "PUT", "/inbound-settings", map[string]any{"notify_failures": false})
	e.want(code, 200, b, "tercih kapat")
	code, b = e.as(alice, "PUT", "/inbound-settings", map[string]any{})
	e.want(code, 400, b, "eksik alan")
	e.mail(alice, noAmount)
	if len(rec.list()) != 2 {
		t.Fatal("tercih kapalıyken bildirim gitmemeli")
	}
	code, b = e.as(alice, "PUT", "/inbound-settings", map[string]any{"notify_failures": true})
	e.want(code, 200, b, "tercih aç")

	// Saatlik sınır: kullanıcı başına en fazla 5.
	for i := 0; i < 6; i++ {
		e.mail(alice, noAmount)
	}
	if l := rec.list(); len(l) != maxFailureNoticesPerHour {
		t.Fatalf("saatlik sınır %d, gelen %d", maxFailureNoticesPerHour, len(l))
	}
	// Başka kullanıcı etkilenmez; kuyruk doluysa düşer ama webhook yine 200.
	e.mail(bob, noAmount)
	if l := rec.list(); len(l) != maxFailureNoticesPerHour+1 || l[len(l)-1].UserID != bob {
		t.Fatalf("bob bildirimi: %+v", l)
	}
	rec.full = true
	if st, _ := e.mail(bob, noAmount); st != 200 {
		t.Fatalf("kuyruk dolu: %d", st)
	}

	// Gövdesi okunamayan (413) mail, ?rcpt= alias'ı geçerliyse bildirilir (early reject).
	rec.full = false
	before := len(rec.list())
	e.h.recordEarlyReject(e.inboundAddress(bob).Address, rejectedTooLarge)
	if l := rec.list(); len(l) != before+1 || !strings.Contains(l[len(l)-1].Reason, "boyut") {
		t.Fatalf("too_large bildirimi: %+v", l)
	}
}
