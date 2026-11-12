# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Fissio: smart receipt processing and micro-expense management (Turkish-language UI/comments). Monorepo with three backend microservices (Docker Compose) and a Flutter mobile app. Note: README.md is in a legacy (non-UTF-8) encoding — don't edit it with Edit/Write.

## Commands

Backend (repo root; copy `.env.example` to `.env` for config, defaults work for dev):
- `docker compose up --build` — starts postgres, auth (host :8081), expense (:8082), ocr (:8083). Postgres is internal-only (not exposed). Schema comes from `db/init.sql` (runs only on first volume init).
- Go services (`services/auth`, `services/expense`, Go 1.25, gin + lib/pq + golang-jwt): from the service dir, `go test ./...`; single test: `go test -run TestName ./...`. Only `expense` has tests (`parser_test.go`).
- OCR service (`services/ocr`, Python 3.11, FastAPI): `pytest tests/` (needs `requirements.txt` incl. paddleocr/paddlepaddle); run locally with `uvicorn app:app --port 8080`.

Mobile (`fissio_mobile/`): `flutter pub get`, `flutter run`, `flutter test`, single test: `flutter test test/ocr_engine_test.dart`, `flutter analyze`.

## Architecture

- **auth** (Go): register/login, issues JWTs signed with `JWT_SECRET`.
- **expense** (Go): validates the same JWT itself (own `jwt.go`; no call to auth — `JWT_SECRET` must match in both). Routes under `/api` in `main.go`: categories, `receipts/parse` (text → structured fields via `parser.go`), `receipts/scan` (image → OCR → parse), expenses CRUD, `reports/summary`. Direct `database/sql` access in `db.go`/`handlers.go`; CORS handled by hand in `main.go`.
- **ocr** (Python): receipt OCR using Strategy + Factory Registry (`ocr/base.py`, `factory.py`, `paddle_engine.py`, `custom_engine.py`, `config.py`). Engine chosen per request via `?engine=`, `X-OCR-Engine` header, or `OCR_ENGINE` env (default `paddleocr`, PP-OCRv4 mobile, `OCR_LANG=tr`). Endpoint: `/ocr/extract` (base64 image JSON, also multipart).
- The same Strategy pattern is mirrored in **expense** (`ocr_engine.go`: `OcrEngine` interface, `RemoteMicroserviceOcrEngine` delegating to `OCR_SERVICE_URL`, factory from env) and in the **mobile** app (`lib/ocr/ocr_engine.dart`). Adding an OCR engine means touching these layers consistently; the JSON shape (`raw_text`, `blocks`, `confidence`, `engine`, `model_version`, `elapsed_ms`) is shared across all three.
- **Mobile** (Flutter, plain `ChangeNotifier`-style state in `app_state.dart`, no heavy framework): `api.dart` is the single HTTP client (auth :8081, expense :8082, ocr :8083; host is `10.0.2.2` on Android emulator, else `localhost`); tokens stored via `flutter_secure_storage`; screens in `lib/pages/`; scan flow in `scan_page.dart` → `receipt_form_page.dart`.
