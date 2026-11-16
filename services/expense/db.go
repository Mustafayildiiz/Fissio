package main

import (
	"database/sql"

	"github.com/lib/pq"
)

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
`); err != nil {
		return err
	}

	seed := []struct {
		name string
		kw   []string
	}{
		{"Market", []string{"bim", "migros", "a101", "sok", "carrefour", "carrefoursa", "macro", "macrocenter", "market", "bakkal", "file market"}},
		{"Akaryakıt", []string{"opet", "shell", "bp", "petrol ofisi", "total", "aytemiz", "akaryakit", "benzin", "motorin", "lpg"}},
		{"Restoran & Kafe", []string{"starbucks", "mcdonalds", "burger king", "kfc", "dominos", "simit sarayi", "kafe", "cafe", "restoran", "lokanta", "kebap", "pizza"}},
		{"Sağlık", []string{"eczane", "hastane", "klinik", "eczanesi"}},
		{"Giyim", []string{"lc waikiki", "lcw", "koton", "defacto", "zara", "mavi", "boyner"}},
		{"Ulaşım", []string{"taksi", "otopark", "otobus", "metro", "istanbulkart", "hgs", "ogs"}},
		{"Fatura", []string{"turkcell", "vodafone", "turk telekom", "enerjisa", "igdas", "iski", "elektrik", "dogalgaz"}},
		{"Diğer", nil},
	}
	for _, s := range seed {
		// Zaten varsa dokunma: kullanicinin sonradan yaptigi degisiklikler korunur.
		if _, err := db.Exec(
			`INSERT INTO expense.categories (name, keywords) VALUES ($1, $2) ON CONFLICT (name) DO NOTHING`,
			s.name, pq.Array(append([]string{}, s.kw...))); err != nil {
			return err
		}
	}
	return nil
}
