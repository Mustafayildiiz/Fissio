package main

import "database/sql"

// Not: Ham fis metni saklanmaz. Fis fotograflari yalnizca fise bagli, hesaba ozel kullanici verisi
// olarak saklanir (expense.receipt_images, fis silinince silinir); OCR servisi hicbir sey saklamaz.
func migrate(db *sql.DB) error {
	if _, err := db.Exec(`
CREATE SCHEMA IF NOT EXISTS expense;
CREATE TABLE IF NOT EXISTS expense.categories (
	id       SERIAL PRIMARY KEY,
	name     TEXT NOT NULL UNIQUE,
	keywords TEXT[] NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS expense.expenses (
	id          BIGSERIAL PRIMARY KEY,
	user_id     BIGINT NOT NULL,
	merchant    TEXT NOT NULL DEFAULT '',
	amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
	spent_at    DATE NOT NULL,
	category_id INT NOT NULL REFERENCES expense.categories(id),
	created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_expenses_user_date ON expense.expenses (user_id, spent_at);
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS note  TEXT  NOT NULL DEFAULT '';
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS items JSONB NOT NULL DEFAULT '[]';
CREATE TABLE IF NOT EXISTS expense.receipt_images (
	id           BIGSERIAL PRIMARY KEY,
	expense_id   BIGINT NOT NULL REFERENCES expense.expenses(id) ON DELETE CASCADE,
	user_id      BIGINT NOT NULL,
	position     INT NOT NULL,
	content_type TEXT NOT NULL,
	data         BYTEA NOT NULL,
	created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_receipt_images_expense ON expense.receipt_images (expense_id, position);
-- Kullanicinin kategori duzeltmelerinden ogrenilen kisisel kurallar (bkz. rules.go, categorizer.go).
CREATE TABLE IF NOT EXISTS expense.category_rules (
	id          BIGSERIAL PRIMARY KEY,
	user_id     BIGINT NOT NULL,
	kind        TEXT NOT NULL CHECK (kind IN ('merchant','item')),
	pattern     TEXT NOT NULL,
	category_id INT NOT NULL REFERENCES expense.categories(id),
	hits        INT NOT NULL DEFAULT 1,
	updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
	UNIQUE (user_id, kind, pattern)
);
`); err != nil {
		return err
	}

	if err := migrateProfiles(db); err != nil {
		return err
	}

	if err := migrateTaxonomy(db); err != nil {
		return err
	}

	if err := migrateBudgetsAndRecurring(db); err != nil {
		return err
	}

	if err := migrateInbound(db); err != nil {
		return err
	}

	// Marka ve urun sozlugu kodda (internal/receiptparse/category_lexicon.go); keywords kolonu ek/ozel marka anahtar
	// kelimeleri icindir ve bos baslar.
	seed := []string{
		"Market / Gıda", "Restoran / Kafe", "Akaryakıt / Ulaşım", "Giyim", "Elektronik",
		"Sağlık / Eczane", "Fatura / Abonelik", "Ev / Yaşam", "Kişisel Bakım", "Eğlence / Hobi", "Diğer",
	}
	for _, name := range seed {
		// Zaten varsa dokunma: kullanicinin sonradan yaptigi degisiklikler korunur.
		if _, err := db.Exec(
			`INSERT INTO expense.categories (name, keywords) VALUES ($1, '{}') ON CONFLICT (name) DO NOTHING`,
			name); err != nil {
			return err
		}
	}
	return nil
}

// migrateTaxonomy eski 8'li kategori setini yeni taksonomiye tasir (idempotent): adlari degistirir,
// "Ulaşım"i "Akaryakıt / Ulaşım"a birlestirir. Yeni kategoriler seed ile eklenir.
func migrateTaxonomy(db *sql.DB) error {
	renames := [][2]string{
		{"Market", "Market / Gıda"},
		{"Restoran & Kafe", "Restoran / Kafe"},
		{"Akaryakıt", "Akaryakıt / Ulaşım"},
		{"Sağlık", "Sağlık / Eczane"},
		{"Fatura", "Fatura / Abonelik"},
	}
	for _, r := range renames {
		// Hedef ad zaten varsa dokunma (elle yapilmis degisiklikler korunur).
		if _, err := db.Exec(`UPDATE expense.categories SET name = $2
			WHERE name = $1 AND NOT EXISTS (SELECT 1 FROM expense.categories WHERE name = $2)`, r[0], r[1]); err != nil {
			return err
		}
	}
	// "Ulaşım" -> "Akaryakıt / Ulaşım" birlestirme: harcamalar ve kurallar yeni kategoriye tasinir, eski satir silinir.
	for _, tbl := range []string{"expense.expenses", "expense.category_rules"} {
		if _, err := db.Exec(`UPDATE ` + tbl + ` SET category_id = (SELECT id FROM expense.categories WHERE name = 'Akaryakıt / Ulaşım')
			WHERE category_id = (SELECT id FROM expense.categories WHERE name = 'Ulaşım')
			  AND EXISTS (SELECT 1 FROM expense.categories WHERE name = 'Akaryakıt / Ulaşım')`); err != nil {
			return err
		}
	}
	if _, err := db.Exec(`DELETE FROM expense.categories c WHERE c.name = 'Ulaşım'
		AND EXISTS (SELECT 1 FROM expense.categories WHERE name = 'Akaryakıt / Ulaşım')
		AND NOT EXISTS (SELECT 1 FROM expense.expenses e WHERE e.category_id = c.id)
		AND NOT EXISTS (SELECT 1 FROM expense.category_rules r WHERE r.category_id = c.id)`); err != nil {
		return err
	}
	// "ELEKTRIK KESILDI" bilgi satiri fis kategorisini Fatura'ya cekmesin.
	_, err := db.Exec(`UPDATE expense.categories SET keywords = array_remove(array_remove(keywords, 'elektrik'), 'dogalgaz')
		WHERE keywords && ARRAY['elektrik','dogalgaz']`)
	return err
}

// migrateBudgetsAndRecurring (idempotent):
//   - expense.budgets: profil + kategori basina aylik harcama limiti (profil silinince ON DELETE CASCADE);
//     category_id NULL = profilin toplam aylik butcesi.
//   - expenses.recurring_day (1-31, NULL = tekrarlamaz) ve recurring_remind: "Her ay tekrarlanir" isareti
//     ve odeme hatirlatici tercihi; recurring_kind (fixed|variable) ve recurring_estimate (degisken fatura tahmini).
//     Seri/projeksiyon hesabi recurring.go'da.
//   - expenses.updated_at (+ (user_id, updated_at) indeksi): cakisma denetimi ve artimli senkron.
func migrateBudgetsAndRecurring(db *sql.DB) error {
	_, err := db.Exec(`
CREATE TABLE IF NOT EXISTS expense.budgets (
	id            BIGSERIAL PRIMARY KEY,
	user_id       BIGINT NOT NULL,
	profile_id    BIGINT NOT NULL REFERENCES expense.profiles(id) ON DELETE CASCADE,
	category_id   INT REFERENCES expense.categories(id),
	monthly_limit NUMERIC(12,2) NOT NULL CHECK (monthly_limit > 0),
	updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
	UNIQUE (profile_id, category_id)
);
CREATE INDEX IF NOT EXISTS idx_budgets_user ON expense.budgets (user_id);
-- category_id NULL = profilin TOPLAM aylik butcesi (tum kategoriler). UNIQUE (profile_id, category_id) NULL'lari
-- birbirinden farkli sayar; profil basina tek toplam limit icin kismi tekil indeks gerekir.
ALTER TABLE expense.budgets ALTER COLUMN category_id DROP NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_budgets_total ON expense.budgets (profile_id) WHERE category_id IS NULL;
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS recurring_day INT CHECK (recurring_day BETWEEN 1 AND 31);
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS recurring_remind BOOLEAN NOT NULL DEFAULT TRUE;
-- Tekrar turu: sabit (kira, abonelik) / degisken (elektrik, su, dogalgaz faturasi) ve degisken icin tahmini tutar.
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS recurring_kind TEXT NOT NULL DEFAULT 'fixed' CHECK (recurring_kind IN ('fixed','variable'));
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS recurring_estimate NUMERIC(12,2) CHECK (recurring_estimate > 0);
-- ocr_engine: fisi okuyan OCR motoru (paddleocr | custom | mlkit); NULL = manuel girilen / eski kayit. Yalniz bilgi amacli.
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS ocr_engine TEXT;
-- document_no: dijital fatura kimligi (ETTN UUID ya da VKN_FaturaNo). Ayni hesapta ayni belge ikinci kez eklenemez
-- (kismi tekil indeks); NULL (fis/manuel/numarasiz belge) mukerrer denetimine girmez.
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS document_no TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_expenses_document_no ON expense.expenses (user_id, document_no) WHERE document_no IS NOT NULL;
-- order_id: platform siparis kodu (Yemeksepeti/Trendyol/Google Play...). has_official_invoice: kayit resmi bir E-Arsiv/E-Fatura
-- belgesine dayaniyor mu — document_no'dan TURETILIR (API'de salt okunur; geri alinamaz kilit: document_no PUT ile silinemez).
-- Ayni hesapta ayni siparis kodu + ayni belge turu ikinci kez eklenemez; on ozet (false) ile resmi fatura (true) bir arada
-- bulunabilir ve smart-merge (bkz. digital_merge.go) ikisini tek kayda indirir.
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS order_id TEXT;
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS has_official_invoice BOOLEAN GENERATED ALWAYS AS (document_no IS NOT NULL) STORED;
CREATE UNIQUE INDEX IF NOT EXISTS uq_expenses_order_kind ON expense.expenses (user_id, order_id, has_official_invoice) WHERE order_id IS NOT NULL;
-- merged_client_uids: bu kayda BIRLESTIRILEN fislerin client_uid'leri. Birlestirme yeni kayit acmadigindan, yaniti kaybolan bir
-- istegin (cevrimdisi kuyruk / webhook yeniden denemesi) tekrari mukerrer gorunurdu; artik ayni client_uid ayni hedefe cozulur.
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS merged_client_uids TEXT[] NOT NULL DEFAULT '{}';
CREATE INDEX IF NOT EXISTS idx_expenses_user_spent ON expense.expenses (user_id, spent_at);
CREATE INDEX IF NOT EXISTS idx_expenses_recurring ON expense.expenses (profile_id) WHERE recurring_day IS NOT NULL;
-- Son degisiklik zamani: iyimser eszamanlilik (PUT base_updated_at -> 409) ve artimli liste (GET /expenses?since=).
-- INSERT varsayilanla, her UPDATE acikca (bkz. updateExpense) gunceller; fotograf ekleme/silme guncellemez.
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
CREATE INDEX IF NOT EXISTS idx_expenses_user_updated ON expense.expenses (user_id, updated_at);`)
	return err
}

// migrateInbound e-posta ile otomatik fis aktarimi tablolari (idempotent). Hepsi PROFIL bazlidir:
//   - inbound_aliases: (user_id, profile_id) basina tek, tahmin edilemez yonlendirme takma adi
//     (<alias>@INBOUND_EMAIL_DOMAIN); o adrese gelen fisler dogrudan o profile kaydedilir; last_* = son aktarim durumu.
//   - forwarding_confirmations: Gmail yonlendirme onay kodu/baglantisi (fis degildir; mobil istemci ceker), profil bazli.
//   - inbound_history: her gelen mailin akibeti (saved/ignored/failed + neden + fis kimligi); icerik saklanmaz.
//   - inbound_settings: kullanici duzeyi tercih (basarisiz aktarimda hesap e-postasina bildirim).
//
// profile_id FK'lari ON DELETE CASCADE: profil silinince adresi, onaylari ve gecmisi de gider.
// Eski (kullanici basina tek alias, profile_id NULL olabilen) sema yerinde donusturulur: NULL profile_id ve
// onay/gecmis satirlari kullanicinin varsayilan (en eski) profiline baglanir; profili olmayan alias sahibine varsayilan
// profil acilir (kurulu yonlendirme bozulmasin). PK/FK donusumleri pg_constraint kontrolluydu: tekrar calismada no-op.
//
// Hepsi user_id tasir: hesap silinince internal.go userOwnedTables ile temizlenir.
func migrateInbound(db *sql.DB) error {
	_, err := db.Exec(`
CREATE TABLE IF NOT EXISTS expense.inbound_aliases (
	user_id          BIGINT NOT NULL,
	profile_id       BIGINT NOT NULL REFERENCES expense.profiles(id) ON DELETE CASCADE,
	alias            TEXT NOT NULL UNIQUE,
	created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
	last_received_at TIMESTAMPTZ,
	last_status      TEXT,
	paused           BOOLEAN NOT NULL DEFAULT false,
	PRIMARY KEY (user_id, profile_id)
);
ALTER TABLE expense.inbound_aliases ADD COLUMN IF NOT EXISTS paused BOOLEAN NOT NULL DEFAULT false;
CREATE TABLE IF NOT EXISTS expense.forwarding_confirmations (
	id          BIGSERIAL PRIMARY KEY,
	user_id     BIGINT NOT NULL,
	profile_id  BIGINT NOT NULL REFERENCES expense.profiles(id) ON DELETE CASCADE,
	code        TEXT NOT NULL,
	link        TEXT,
	received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_forwarding_conf_user ON expense.forwarding_confirmations (user_id, received_at DESC);
CREATE TABLE IF NOT EXISTS expense.inbound_history (
	id          BIGSERIAL PRIMARY KEY,
	user_id     BIGINT NOT NULL,
	profile_id  BIGINT NOT NULL REFERENCES expense.profiles(id) ON DELETE CASCADE,
	received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
	source      TEXT NOT NULL DEFAULT 'email',
	from_addr   TEXT,
	subject     TEXT,
	status      TEXT NOT NULL CHECK (status IN ('saved', 'ignored', 'failed')),
	reason      TEXT,
	expense_id  BIGINT REFERENCES expense.expenses(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_inbound_history_user ON expense.inbound_history (user_id, received_at DESC);
CREATE TABLE IF NOT EXISTS expense.inbound_settings (
	user_id         BIGINT PRIMARY KEY,
	notify_failures BOOLEAN NOT NULL DEFAULT true
);

-- Eski semadan donusum (taze semada hepsi no-op).
INSERT INTO expense.profiles (user_id, name, client_uid)
	SELECT DISTINCT a.user_id, 'Kişisel', 'srv-default-' || a.user_id FROM expense.inbound_aliases a
	WHERE NOT EXISTS (SELECT 1 FROM expense.profiles p WHERE p.user_id = a.user_id)
	ON CONFLICT (user_id, client_uid) DO NOTHING;
UPDATE expense.inbound_aliases a
	SET profile_id = (SELECT min(p.id) FROM expense.profiles p WHERE p.user_id = a.user_id)
	WHERE a.profile_id IS NULL;

ALTER TABLE expense.forwarding_confirmations ADD COLUMN IF NOT EXISTS profile_id BIGINT REFERENCES expense.profiles(id) ON DELETE CASCADE;
UPDATE expense.forwarding_confirmations f
	SET profile_id = (SELECT min(a.profile_id) FROM expense.inbound_aliases a WHERE a.user_id = f.user_id)
	WHERE f.profile_id IS NULL;
DELETE FROM expense.forwarding_confirmations WHERE profile_id IS NULL;
ALTER TABLE expense.forwarding_confirmations ALTER COLUMN profile_id SET NOT NULL;

ALTER TABLE expense.inbound_history ADD COLUMN IF NOT EXISTS profile_id BIGINT REFERENCES expense.profiles(id) ON DELETE CASCADE;
UPDATE expense.inbound_history h
	SET profile_id = COALESCE(
		(SELECT min(a.profile_id) FROM expense.inbound_aliases a WHERE a.user_id = h.user_id),
		(SELECT min(p.id) FROM expense.profiles p WHERE p.user_id = h.user_id))
	WHERE h.profile_id IS NULL;
DELETE FROM expense.inbound_history WHERE profile_id IS NULL;
ALTER TABLE expense.inbound_history ALTER COLUMN profile_id SET NOT NULL;

-- Eski PK (yalniz user_id) -> (user_id, profile_id).
DO $$
DECLARE pk record;
BEGIN
	SELECT conname, array_length(conkey, 1) AS n INTO pk FROM pg_constraint
		WHERE conrelid = 'expense.inbound_aliases'::regclass AND contype = 'p';
	IF pk.n = 1 THEN
		EXECUTE format('ALTER TABLE expense.inbound_aliases DROP CONSTRAINT %I', pk.conname);
		ALTER TABLE expense.inbound_aliases ADD PRIMARY KEY (user_id, profile_id);
	END IF;
END $$;

-- Eski FK (ON DELETE SET NULL) -> CASCADE: NOT NULL kolonda SET NULL profil silmeyi 500'e cevirirdi.
DO $$
DECLARE fk record;
BEGIN
	FOR fk IN SELECT conname, conrelid::regclass AS tbl FROM pg_constraint
		WHERE contype = 'f' AND confrelid = 'expense.profiles'::regclass AND confdeltype <> 'c'
		  AND conrelid IN ('expense.inbound_aliases'::regclass, 'expense.forwarding_confirmations'::regclass,
		                   'expense.inbound_history'::regclass)
	LOOP
		EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', fk.tbl, fk.conname);
		EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (profile_id) REFERENCES expense.profiles(id) ON DELETE CASCADE',
			fk.tbl, fk.conname);
	END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS idx_forwarding_conf_profile ON expense.forwarding_confirmations (user_id, profile_id, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_inbound_history_profile ON expense.inbound_history (user_id, profile_id, received_at DESC);`)
	return err
}

// migrateProfiles hesap altinda izole profilleri kurar (idempotent):
//   - expense.profiles(user_id, name, client_uid); varsayilan profil "Kisisel".
//   - expenses.profile_id eskiden hic kullanilmayan metin kolonuydu ('default'); profile_id_legacy'e tasinir,
//     yerine profiles'a bagli BIGINT profile_id gelir. Mevcut harcamalar kullanici basina "Kisisel" profile baglanir.
//   - expenses.client_uid: istemci/ihrac kimligi; (user_id, client_uid) tekil -> iceri aktarma ve cevrimdisi
//     kuyruk tekrarlari mukerrer kayit uretmez. Mevcut satirlara 'srv-<id>' yazilir.
func migrateProfiles(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`
CREATE TABLE IF NOT EXISTS expense.profiles (
	id         BIGSERIAL PRIMARY KEY,
	user_id    BIGINT NOT NULL,
	name       TEXT NOT NULL,
	client_uid TEXT NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
	UNIQUE (user_id, client_uid)
);
CREATE INDEX IF NOT EXISTS idx_profiles_user ON expense.profiles (user_id);
ALTER TABLE expense.profiles ADD COLUMN IF NOT EXISTS avatar BYTEA;
ALTER TABLE expense.profiles ADD COLUMN IF NOT EXISTS avatar_type TEXT;
ALTER TABLE expense.profiles ADD COLUMN IF NOT EXISTS avatar_version INT NOT NULL DEFAULT 0;`); err != nil {
		return err
	}

	var legacyType sql.NullString
	if err := tx.QueryRow(`SELECT data_type FROM information_schema.columns
		WHERE table_schema='expense' AND table_name='expenses' AND column_name='profile_id'`).Scan(&legacyType); err != nil && err != sql.ErrNoRows {
		return err
	}
	if legacyType.Valid && legacyType.String != "bigint" {
		if _, err := tx.Exec(`ALTER TABLE expense.expenses RENAME COLUMN profile_id TO profile_id_legacy`); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS profile_id BIGINT REFERENCES expense.profiles(id) ON DELETE CASCADE;
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS client_uid TEXT;

INSERT INTO expense.profiles (user_id, name, client_uid)
	SELECT DISTINCT user_id, 'Kişisel', 'srv-default-' || user_id FROM expense.expenses WHERE profile_id IS NULL
	ON CONFLICT (user_id, client_uid) DO NOTHING;
UPDATE expense.expenses e SET profile_id = (SELECT min(p.id) FROM expense.profiles p WHERE p.user_id = e.user_id)
	WHERE e.profile_id IS NULL;
UPDATE expense.expenses SET client_uid = 'srv-' || id WHERE client_uid IS NULL;

ALTER TABLE expense.expenses ALTER COLUMN profile_id SET NOT NULL;
ALTER TABLE expense.expenses ALTER COLUMN client_uid SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_expenses_user_uid ON expense.expenses (user_id, client_uid);
CREATE INDEX IF NOT EXISTS idx_expenses_profile_date ON expense.expenses (profile_id, spent_at);`); err != nil {
		return err
	}
	return tx.Commit()
}
