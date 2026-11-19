# TASKS.md — Fissio mimari denetim planı (uygulama kontrol listesi)

Kaynak plan: `C:\Users\Mustafa\.claude\plans\pasted-content-id-b7ce-fissio-projesini-dynamic-hammock.md` (denetim raporu + onaylı kararlar).
Çalışma kuralları: `CLAUDE.md` → "AUTONOMOUS WORKFLOW RULES".

Gösterim: `- [ ]` bekliyor · `- [x]` bitti ve doğrulandı · `- [!] BLOCKED` engelli. Kod referansları (K1…, O1…) plandaki risk numaralarıdır.

## Onaylanan kararlar (değişmez)
- `expense.exe`: yalnız `git rm --cached` + `*.exe` ignore; geçmiş yeniden yazılmaz, force-push yok.
- Sync AÇIK + online iken cihaz-OCR metni `POST /receipts/parse`'a gönderilir; sync kapalı/çevrimdışıyken metin cihazdan çıkmaz (yerel Dart ayrıştırıcı).
- auth↔expense arasında internal HTTP endpoint'leri (`DELETE /internal/users/:id`, `GET /internal/sessions/:sid`); birbirinin şemasına SQL yok.
- Sıra: Adım 1+2 → ilgili testler yeşil → Adım 3'e geç.

---

## ADIM 1 — Hijyen + Güvenlik
- [x] K1: `docker-compose.yml`'den ocr `ports: "8083:8080"` satırını kaldır (yalnız iç ağ); override ile yerel debug notu ekle
- [x] K1: CLAUDE.md ve `docs/openapi.yaml` içindeki "istemci :8083" ifadelerini düzelt
- [x] K1: README.md'deki `8083` ifadelerini düzelt (README cp1254: önce UTF-8'e çevir, sonra düzenle — Adım 7 ile birlikte)
- [x] K2: OCR `/ocr/extract` base64 alanına `max_length`, `Content-Length` ön kontrolü (413)
- [x] K2: OCR upload/parse uçlarında `file.read(MAX+1)` ile sınırlı okuma
- [x] K2: `OcrConfig.max_image_pixels` (`OCR_MAX_IMAGE_PIXELS`, 25 MP) + decode öncesi piksel kontrolü (400)
- [x] K2: çıkarım semaforu (`OCR_MAX_CONCURRENT`, varsayılan 2)
- [x] K2: `tests/test_limits.py` (piksel sınırı, Content-Length, base64 üst sınırı) — OCR testleri 33/33 yeşil (imaj içinde)
- [x] K5: `usesCleartextTraffic` ana manifestten kaldır; `src/debug` ve `src/profile` manifestlerine ekle
- [x] Repo: `git rm --cached services/expense/expense.exe`
- [x] Repo: kök `.gitignore` genişlet (`*.exe`, `__pycache__/`, `.env.*`+`!.env.example`, `*.iml`, `local.properties`, `coverage/` …)
- [x] Repo: `.gitattributes` (`* text=auto eol=lf`)
- [x] Repo: boş/bozuk `services/ocr;C` dizinini sil
- [x] Repo: auth/expense `.dockerignore` (`*.exe`, `*_test.go`, `.env*`, `.git`) + CRLF düzelt
- [x] Docker: auth/expense/ocr için HEALTHCHECK, `restart: unless-stopped`, `GIN_MODE=release`; expense → auth `service_healthy` bağımlılığı
- [x] `docker compose config -q` geçerli
- [x] Doğrula: `docker compose up --build` ile üç servis `healthy` (auth/expense/ocr healthy; `docker compose build` bake hatası verdiği için imajlar `docker build` ile derlendi, sonra `docker compose up -d --no-build`)
- [x] Doğrula: yığın ayaktayken `curl localhost:8083` bağlanamıyor
- [x] Doğrula: alpine imajında `wget` healthcheck komutu çalışıyor
- [x] Doğrula: `flutter build apk --debug` düz HTTP ile backend'e bağlanıyor; `flutter build apk --release` manifestinde `usesCleartextTraffic` yok
- [x] Not: release derlemesi artık `http://` backend'e bağlanamaz → https (Adım 5 Caddy) gelene kadar release test için profile/debug kullan — README + fissio_mobile/README.md'de belgelendi (`--dart-define=API_BASE=https://...`)

## ADIM 2 — Veri bütünlüğü
### K3 + internal API (auth ↔ expense)
- [x] expense: `internal.go` — `userOwnedTables`, `purgeUser` (tek transaction, idempotent), `internalAuth` (INTERNAL_TOKEN, sabit zamanlı), `buildInternalRouter`, `DELETE /internal/users/:id`
- [x] expense: ayrı iç port (`INTERNAL_PORT`, 9090) — host'a yayınlanmaz; `INTERNAL_TOKEN` yoksa başlamaz
- [x] expense: `TestPGUserOwnedTablesAreAllPurged` (information_schema drift testi), `TestPGPurgeUserRemovesOnlyThatUsersData`, `TestPGInternalPurgeEndpoint`
- [x] auth: `internal.go` — `userPurger`/`httpPurger`, `GET /internal/sessions/:sid` (`{alive, user_id}`, 404/400), `sweepDeletions` + `runDeletionSweeper`
- [x] auth: `auth.users.deleting_at` migration; silinmekte olan hesap login olamaz
- [x] auth: `deleteAccount` yeniden yazıldı (işaretle+oturumları iptal et → expense purge → auth satırlarını sil; expense erişilemezse 202 `deletion_pending`; 15 sn sonra ikinci purge)
- [x] auth: `to_regclass` ile expense şemasına SQL KALDIRILDI
- [x] auth testleri: `fakePurger`, hesap silme, ertelenen silme + sweeper, internal sessions endpoint, `httpPurger`, config `INTERNAL_TOKEN` zorunlu
- [x] expense: `sessionChecker` HTTP'ye geçti (`GET /internal/sessions/:sid`, 10 sn cache, sub==user_id sahiplik kontrolü, hata → 503 `auth_unavailable`, hata önbelleğe yazılmaz)
- [x] expense testleri: `fakeauth_test.go`, `session_checker_test.go`, isolation testleri auth şemasına dokunmadan
- [x] compose/.env.example: `INTERNAL_TOKEN`, `EXPENSE_INTERNAL_URL`, `AUTH_INTERNAL_URL`
- [x] Yerel uçtan uca (docker'sız, gerçek HTTP + test Postgres): register→verify→profil/fiş→hesap sil → expense/auth satırları 0, silinen hesapla login 401, eski token 10 sn sonra `session_revoked`, internal portlar token'sız 401 / public portta 404
- [x] Doğrula: aynı akış `docker compose` içinde (imajlar derlenince; Adım 1 doğrulamasıyla birlikte)
### K6 — zehirli kayıt kuyruğu kilitlemez
- [x] `bulk.go`: kayıt başına SAVEPOINT; DB reddi → per-item `error`; bağlantı/sürücü hatası → 500
- [x] `bulk.go`: `/expenses/bulk` gövde sınırı 10 MB (413)
- [x] `validate()`: NUL/kontrol karakteri temizliği (`cleanText`), yuvarlama sonrası `>= 1e10` taşma kontrolü
- [x] testler: tetikleyici tabanlı zehirli kayıt (`TestPGBulkPoisonItemDoesNotBlockBatch`), NUL temizliği, `validate_test.go`
- [x] mobil `SyncService`: parti reddi → kayıtlar tek tek (`_sendBatch`); kayıt başına hata sayacı (`Expense.syncFailures/syncError`, diske yazılır)
- [x] mobil: fotoğraf yüklemesi `maxImageFailures` (5) sonra bırakılır; fiş sunucuda kalır
- [x] mobil: Veri Yönetimi sayfasında "N kayıt sunucu tarafından kabul edilmedi" satırı (`AppState.failedSyncCount`)
- [x] mobil: üstel geri çekilme 60→120→240→480→900 sn; ilerleme yoksa tam geçmişi yeniden indirme (`_needsRefresh`)
### K7, O7, O9 (mobil)
- [x] K7: `_fromDraft` `recurringKind/recurringEstimate` kopyalıyor (+ çevrimdışı değişken fatura testleri, PUT dahil)
- [x] O7: `skipped` fişte yerel kopya farklıysa PUT (`_reconcileSkipped`, `SyncService.sameContent`); değişmemişse PUT yok
- [x] O9: refresh+flush seri kuyruk (`_exclusive`, Completer kuyruğu — Future zinciri test zone'larında kilitleniyordu)
- [x] O9: flush sırasında hesap/sync değişirse çağrılar durur (`stale()`, `_persist(uid)`)
- [x] `_rerun` tüm sonuçlarda geçerli; ikinci tur "nothing" ise ilk sonuç korunur
- [x] `refresh()` `finally` ile `loading` takılı kalmıyor
- [x] `test/sync_resilience_test.dart` (10 test)
### Adım 2 doğrulama kapısı
- [x] `go vet` + `go test ./...` expense (PG'li, `-p 1`) yeşil
- [x] `go vet` + `go test ./...` auth (PG'li, `-p 1`) yeşil
- [x] `flutter analyze` temiz
- [x] `flutter test` 260/260 yeşil
- [x] CLAUDE.md güncel (internal API, sessionChecker, bulk, mobil sync notları)
- [x] Zayıf test güçlendir: "flush sürerken hesap değişirse" testi yalnızca duman testi (sıkı iddia yok) — başka hesabın token'ıyla istek gitmediğini kanıtlayan sahte backend kaydı ekle
- [!] BLOCKED Adım 1+2 değişikliklerini commit et (kullanıcı isteyince; tek commit değil, adım başına) — commit yalnızca kullanıcı isteyince (çalışma kuralı); tüm değişiklikler çalışma ağacında

---

## ADIM 3 — Cihaz-OCR doğruluğu ve tek doğruluk kaynağı
- [x] Üst düzey `testdata/` dizini oluştur; Go (`../../testdata`), Dart (`../testdata`), Python (`/testdata` mount) yollarını belirle ve belgele
- [x] `testdata/glyphs.json`: Go+Python 20 vektörü + Dart'ta eksik vektörler (`$EKER`, `TE$EKKÜRLER`, `A.$` …); üç test paketi de okusun
- [x] `testdata/rows.json` (blok → beklenen satır) + Python ve Dart testleri
- [x] Dart `reconstructRows`: `local_slope_fn` portu, satır başına yükseklik toleransı + 8 px alt sınır, kararlı sıralama
- [x] `testdata/parse/*.json`: gerçek fiş fixture'ları (`ocrBimKoltuk`, `ocrCanBolat`, `ocrBimKirli`, indirim-zaten-kalemlerde vakası) + `known_divergence` etiketi
- [x] Dart `ocrBimKirli` fixture + testi ekle
- [x] K4: Dart `reconcile` — `discount_already_in_items` dalı + yuvarlanmış fark (float 0.00999… hatası)
- [x] K4: Dart `resolveTotal` (ödenen − para üstü) portu
- [x] Dart `recoverBareAmounts` portu (BIM Koltuk 15 → 17 kalem)
- [x] Dart merchant: marka tabanlı başlık seçimi (Go `parser.go:248-259`)
- [x] Dart `mergePageTexts` (çok sayfalı cihaz taramada dikiş tekrarları)
- [x] KARAR UYGULAMASI: sync AÇIK + online → cihaz-OCR metnini `POST /receipts/parse`'a gönder; sunucu sonucu (kalemler, toplam mutabakatı, kategori) kullanılsın
- [x] KARAR UYGULAMASI: sync kapalı / çevrimdışı → metin cihazdan çıkmaz, yerel ayrıştırıcı; test: bu modda ağ isteği YOK
- [x] `AppState.scanAndParseReceipt` yönlendirme testleri güncelle
- [x] O5: çözüm = online+sync AÇIK iken cihaz-OCR metni sunucu parse'ından geçer (kategori kuralları dahil); çevrimdışı okunan fişler `Diğer`+`category_review` kalır, kullanıcı formda seçer (ham metin saklanmaz)
- [x] O14: Dart `toLowerCase()` → `foldTR` (alışveriş araması `receipts_page.dart`, CSV kategori eşleşmesi `data_transfer.dart`, `fingerprint` — mevcut parmak izi uyumuna dikkat)
- [x] O14: tek Dart `parseMoney` (`lib/money.dart`; budgets + data_transfer buna bağlandı; `receipt_parser/parser.dart` `parseAmount` Go ikizi olarak ayrı kalır, belgelendi); `'1,234.50'` → 1234.5 testi
- [x] Go: `engine` alias'larını Python ile hizala (`pp-ocrv4-mobile`, `fissio_custom`); gerçek registry testi
- [x] Go: OCR `metadata` alanını (`rec_*`) istemciye taşı
- [x] Dart `'Diğer'` literal'lerini tek `kOtherCategory` sabitine indir; boş kategori önbelleğinde `category_id: null` davranışını netleştir/test et
- [x] Doğrulama: Go + Python (imajda, `testdata/` mount) + Flutter testleri yeşil

## ADIM 4 — Ağ / dayanıklılık
- [x] O1: expense `http.Server` zaman aşımları (`ReadHeaderTimeout` 10 sn, `ReadTimeout` ~60 sn, `WriteTimeout`, `IdleTimeout` 60 sn)
- [x] O1: `/receipts/scan` toplam deadline (~90 sn)
- [x] O1: sayfalar `errgroup.SetLimit(2-3)` ile paralel; sayfa sırası korunur
- [x] O1: sayfa başı 20-25 sn zaman aşımı + 1 yeniden deneme (5xx/bağlantı)
- [x] O1: kısmi sonuç + `failed_pages`; hata gövdesinde iç adres/upstream gövdesi sızmasın
- [x] O1: mobil — kısmi sonuçta yalnız başarısız sayfaları yeniden tara akışı; çift dokunma koruması
- [x] O2: kullanıcı başı 1-2 eşzamanlı `/receipts/scan` + hız sınırı
- [x] OCR: çıkarım semaforu (`OCR_MAX_CONCURRENT`) altında 6 sayfalık yük testi (gecikme ve bellek ölç) — 6 eşzamanlı büyük sayfa: 15 sn, ~2,9 GB tepe (limit 4g). BULGU: Paddle predictor iş parçacığı güvenli değil, eşzamanlı çağrı SIGSEGV → çıkarım kilitle serileştirildi + `OCR_WORKERS=2` süreç (test eklendi)
- [x] Docker: tüm servisler root olmayan kullanıcı; kaynak limitleri (özellikle OCR) — auth/expense/ocr non-root, mem/cpu/pids limitleri (ocr 4g/3cpu) compose'ta, ocr imajı gerçek çıkarımla doğrulandı
- [x] Docker: Go Dockerfile'larında `go mod tidy` yerine `COPY go.mod go.sum` + `go mod download` önbellek katmanı (5 denemeli döngü; ağ kesintisine dayanıklı) + root olmayan kullanıcı (auth/expense; OCR hâlâ root)
- [x] OCR bağımlılıkları kilit dosyası / sabit sürümler — `services/ocr/constraints.txt` (pip freeze) Dockerfile'da `-c`
- [x] DB havuz sınırı (`SetMaxOpenConns`) auth + expense
- [x] Doğrulama: Go/Python/Flutter testleri + docker compose sağlıklı — stack healthy, 2 sayfalık gerçek tarama e2e (page_texts, metadata), bozuk görsel 400

## ADIM 5 — Sınır sadeleştirme
- [x] O4: servis başına DB rolü (`fissio_auth`, `fissio_expense`), süper kullanıcı yok; `db/init.sql` + compose
- [x] O4: başlangıçta varsayılan/kısa `JWT_SECRET`, `INTERNAL_TOKEN`, DB parolasını reddet (prod modu)
- [x] O4: asimetrik JWT (EdDSA/RS256) — expense yalnız public key
- [x] `internal/receiptparse` paketine taşı (`parser/summary/reconcile/normalize/merge/categorizer/lexicon`)
- [x] `internal/scan` (OCR istemcisi + sayfa orkestrasyonu)
- [!] BLOCKED `internal/ledger` (expenses, profiles, budgets, recurring, rules, reports) — kasıtlı ertelendi: handler/DB/gin bağımlı (~2.500 satır) taşıma, receiptparse+scan ayrımından sonra getirisi düşük, davranış riski yüksek; ayrı PR olarak planlanmalı (CLAUDE.md "Later")
- [!] BLOCKED `internal/media` + `BlobStore` arayüzü (Postgres impl.) — kasıtlı ertelendi: handler/DB/gin bağımlı (~2.500 satır) taşıma, receiptparse+scan ayrımından sonra getirisi düşük, davranış riski yüksek; ayrı PR olarak planlanmalı (CLAUDE.md "Later")
- [x] JWT/CORS/config kopyaları için auth↔expense sözleşme testi (`code:"internal"` hizası) — `contract_test.go` (auth+expense aynı beklentiler); expense hata gövdelerine `code:"internal"` eklendi
- [x] CORS: kaynak listesini env'e bağla veya mobil için kaldır; OCR'da CORS kapat — auth (`netconfig.go corsFor`) + OCR (`OCR_CORS_ORIGINS`) ✓; expense `main.go cors()` agent'ın `internal/` taşımasından sonra aynı `corsFor` ile değiştirilecek — `corsFor` auth+expense, OCR `OCR_CORS_ORIGINS`; production varsayılanı kapalı
- [x] Caddy ters vekil + TLS; tek origin (`/auth/*` → auth, geri kalan → expense); mobil `api.dart` tek base URL
- [x] auth `SetTrustedProxies` / `X-Forwarded-For` ayarı (Caddy ile birlikte; hız sınırı + `sessions.ip`)
- [!] BLOCKED Release derlemesi https ile doğrula (K5 ile birlikte) — gerçek cihaz/emülatör + güvenilir sertifika gerekir. Doğrulananlar: release manifest'te cleartext yok, `API_BASE` https tanımı derleniyor, Caddy TLS ile `curl -k https://localhost:8443/health` ve `/auth/login` yönlendirmesi çalışıyor
- [x] Go `spent/status` ve `/recurring` "gölge" kopyaları: sil veya altın vektörle test et (karar ver) — KARAR: tutuldu (sunucu bütçe API'si, `budgets_pg_test.go` ve toplam-bütçe testleri kapsıyor); mobil yetkili kaynak, CLAUDE.md'de 'shadow' notu

## ADIM 6 — Reaktivite, widget, offline cilası
- [x] O6: ay/gün dönümünde `notifyListeners` (tick + resume'da yıl-ay karşılaştır)
- [x] O6: Android widget otomatik yenileme (`ACTION_DATE_CHANGED/TIME_SET/TIMEZONE_CHANGED` alıcısı veya ay anahtarı)
- [x] O8: `buildRecurring` önbelleği (veri sürümü + gün anahtarı); türev işler zaten tek microtask'ta birleşiyor ve tutar/hatırlatıcı imzası değişmedikçe iş yapılmıyor (zamanlayıcılı debounce testleri kırıyordu, gerek kalmadı)
- [x] O8: flush'ta toplu persist (kalem başına tüm `data.json` yazma yok)
- [x] O8: delta sync (`GET /expenses?since=`) — sunucu + istemci
- [x] O10: vadesi geçmiş ödenmemiş fatura "gecikmiş" olarak listede/hatırlatmada kalsın (Go `recurring.go` + Dart `recurring.dart` + ortak vektör)
- [x] O11: release imzası (`android/key.properties`, örnek dosya; yoksa debug + uyarı, `FISSIO_REQUIRE_RELEASE_KEY=true` ise hata), `applicationId = app.fissio.mobile` (namespace `com.example.fissio_mobile` kaynak paketi olarak kaldı), `MainActivity.kt` ikon bileşen adları sınıf paketinden türetiliyor. NOT: applicationId değişti → eski com.example kurulumu ayrı uygulama olur
- [!] BLOCKED O12: iOS Widget Extension'ı Xcode projesine ekle + App Group + entitlements (Mac gerekir); `Timeline` gece yarısına kur — Xcode/Mac gerekir (bu ortam Windows); iOS widget kaynağı `ios/FissioWidget/` hazır ama Xcode hedefi + App Group + entitlements bir Mac'te eklenmeli. `Timeline` gece yarısı yenileme de aynı oturumda yapılmalı
- [x] Android `allowBackup="false"` veya `dataExtractionRules` (data.json + secure prefs hariç)
- [x] Widget: `previewLayout`; non-red ikon alias'larına `fissio://` VIEW filtresi
- [x] Senkron sonrası sunucu fişini `cloudExpenses`'a hemen ekle (açık detay sayfasında "Fiş bulunamadı" ve refresh başarısızlığında kaybolma)
- [x] O7 devamı: `expenses.updated_at` + `If-Unmodified-Since`/409 (kör last-write-wins'i kaldır)
- [x] Çevrimdışı fotoğraf/avatar önbelleği (`Image.network` yerine disk önbelleği)
- [x] Değişken fatura penceresi: "son 3 takvim ayı", gelecek tarihli fiş hariç, seri bitirme

## ADIM 7 — Sözleşme, dokümantasyon, CI
- [x] `docs/openapi.yaml`: eksik route'lar (`/health`×3, `/ocr/engines`, `/ocr/extract/upload`, `/ocr/parse`), `OcrResult.metadata/page_count`, `Error.code`, `/receipts/scan` 5 MB/sayfa, 503 `auth_unavailable`, `/expenses/bulk` 413
- [x] Go: route-vs-spec testi (`buildRouter(...).Routes()` ↔ YAML); FastAPI `app.openapi()` testi — auth ✓, FastAPI ✓ (`test_openapi_contract.py`); expense testi agent'ın sunucu değişikliklerinden sonra
- [x] README.md'yi UTF-8'e çevir ve güncelle (`:8083`, mimari özet)
- [x] `fissio_mobile/README.md` Flutter şablonunu güncelle/kaldır
- [x] CLAUDE.md: glif kopya sayısı (3), OCR/Go/Dart yetki kaynakları tablosu (Adım 3 sonrası)
- [x] `.github/workflows/`: `go test` (auth, expense; PG servis konteyneri), `pytest` (imaj), `flutter analyze` + `flutter test`
- [x] `.vscode/settings.json` Java gürültüsünü temizle
- [x] Son doğrulama: tüm paketler + `docker compose up --build` + manuel e2e kontrol listesi (plan "Doğrulama" bölümü)
