-- MEVCUT bir veritabanını servis başına rollere dönüştürür (yeni kurulumlarda db/10-roles.sh bunu zaten yapar).
-- Süper kullanıcıyla bir kez çalıştırın, sonra servislerin DATABASE_URL'sini rollere çevirin (.env.example):
--   docker compose exec -T postgres psql -U fissio -d fissio \
--     -v auth_pw=ROL_PAROLASI_1 -v expense_pw=ROL_PAROLASI_2 -v dbname=fissio < db/migrate-roles.sql
-- Geri dönüş: servislerin DATABASE_URL'sini süper kullanıcıya çevirmek yeterlidir (nesne sahipliği değişse de çalışır).
\set ON_ERROR_STOP on

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'fissio_auth', :'auth_pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fissio_auth') \gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'fissio_expense', :'expense_pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fissio_expense') \gexec
ALTER ROLE fissio_auth PASSWORD :'auth_pw';
ALTER ROLE fissio_expense PASSWORD :'expense_pw';

REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
GRANT CONNECT, CREATE ON DATABASE :"dbname" TO fissio_auth, fissio_expense;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS expense;
ALTER SCHEMA auth OWNER TO fissio_auth;
ALTER SCHEMA expense OWNER TO fissio_expense;
ALTER ROLE fissio_auth SET search_path = auth;
ALTER ROLE fissio_expense SET search_path = expense;

-- Şemadaki tablo / sequence / view sahipliği
SELECT format('ALTER TABLE %I.%I OWNER TO fissio_auth', schemaname, tablename) FROM pg_tables WHERE schemaname = 'auth' \gexec
SELECT format('ALTER TABLE %I.%I OWNER TO fissio_expense', schemaname, tablename) FROM pg_tables WHERE schemaname = 'expense' \gexec
SELECT format('ALTER SEQUENCE %I.%I OWNER TO fissio_auth', schemaname, sequencename) FROM pg_sequences WHERE schemaname = 'auth' \gexec
SELECT format('ALTER SEQUENCE %I.%I OWNER TO fissio_expense', schemaname, sequencename) FROM pg_sequences WHERE schemaname = 'expense' \gexec
SELECT format('ALTER VIEW %I.%I OWNER TO fissio_auth', schemaname, viewname) FROM pg_views WHERE schemaname = 'auth' \gexec
SELECT format('ALTER VIEW %I.%I OWNER TO fissio_expense', schemaname, viewname) FROM pg_views WHERE schemaname = 'expense' \gexec
