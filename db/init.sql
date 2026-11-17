CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS expense;
-- Tablolar burada DEGIL, servisler acilirken idempotent olarak olusturulur/guncellenir:
--   auth   : services/auth/main.go    -> migrate()   (users, email_otps, sessions, refresh_tokens)
--   expense: services/expense/db.go   -> migrate() / migrateProfiles() (categories, profiles, expenses, receipt_images, category_rules)
-- Bu dosya yalnizca sema adlarini olusturur ve sadece ilk volume kurulumunda calisir.
