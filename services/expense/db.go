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
ALTER TABLE expense.expenses ADD COLUMN IF NOT EXISTS profile_id TEXT NOT NULL DEFAULT 'default';
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

	if err := migrateTaxonomy(db); err != nil {
		return err
	}

	// Marka ve urun sozlugu kodda (category_lexicon.go); keywords kolonu ek/ozel marka anahtar
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
