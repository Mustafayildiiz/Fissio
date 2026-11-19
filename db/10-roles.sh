#!/bin/sh
# Servis başına veritabanı rolü (en az yetki). Yalnızca İLK volume kurulumunda çalışır (docker-entrypoint-initdb.d).
#   fissio_auth    : yalnızca `auth` şemasının sahibi
#   fissio_expense : yalnızca `expense` şemasının sahibi
# Biri ele geçirilirse diğerinin şemasını (ör. auth.users.password_hash) okuyamaz/yazamaz. Postgres süper kullanıcısı
# (POSTGRES_USER) yalnızca yönetim/bakım içindir; servislere verilmez (bkz. .env.example: AUTH_DATABASE_URL / EXPENSE_DATABASE_URL).
# Var olan bir veritabanını dönüştürmek için: db/migrate-roles.sql
set -eu

AUTH_PW="${AUTH_DB_PASSWORD:-fissio_auth_dev_password}"
EXPENSE_PW="${EXPENSE_DB_PASSWORD:-fissio_expense_dev_password}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v auth_pw="$AUTH_PW" -v expense_pw="$EXPENSE_PW" -v dbname="$POSTGRES_DB" <<'SQL'
CREATE ROLE fissio_auth LOGIN PASSWORD :'auth_pw';
CREATE ROLE fissio_expense LOGIN PASSWORD :'expense_pw';

-- Herkesin (PUBLIC) varsayılan yetkilerini kaldır; yalnızca bağlanma ve kendi şeması.
REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
-- CREATE: servislerin migrate() adimindaki `CREATE SCHEMA IF NOT EXISTS` varlik kontrolu de veritabani CREATE yetkisi ister;
-- baska rolun şemasındaki nesnelere erişim buna rağmen kapalıdır.
GRANT CONNECT, CREATE ON DATABASE :"dbname" TO fissio_auth, fissio_expense;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

CREATE SCHEMA auth AUTHORIZATION fissio_auth;
CREATE SCHEMA expense AUTHORIZATION fissio_expense;
ALTER ROLE fissio_auth SET search_path = auth;
ALTER ROLE fissio_expense SET search_path = expense;
SQL
