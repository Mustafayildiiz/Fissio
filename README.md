# Fissio

Akýllý fiþ iþleme ve mikro harcama yönetimi. Fiþin fotoðrafýný çekin; Fissio metni okuyup maðaza, tarih, toplam ve ürün kalemlerini çýkarýr, kategorilere ayýrýr ve harcamalarýnýzý raporlar.

## Özellikler

- **Fiþ tarama (OCR):** Kamera veya galeriden, uzun fiþler için en fazla 6 sayfa. Sunucu OCR (PaddleOCR) ya da cihaz içi OCR (ML Kit).
- **Otomatik ayrýþtýrma:** Maðaza, tarih, toplam, ürün kalemleri; toplam uyuþmazlýðýnda inceleme uyarýsý.
- **Otomatik kategorilendirme:** 11 kategorili sözlük + düzeltmelerinizden öðrenen kiþisel kurallar.
- **Profiller:** Her hesapta birden fazla harcama profili (varsayýlan "Kiþisel").
- **Çevrimdýþý kullaným ve bulut eþitleme:** Baðlantý yokken fiþler cihazda kuyruða alýnýr, baðlantý gelince eþitlenir. Eþitleme kapalýyken hiçbir veri sunucuya gitmez.
- **Güvenli hesap:** E-posta doðrulama kodu (OTP), kýsa ömürlü eriþim + yenilenen oturum belirteci, oturum yönetimi, kod ile þifre sýfýrlama, hesap silme.
- **Veri taþýma:** JSON yedek ve CSV dýþa/içe aktarma.
- **Kiþiselleþtirme:** Açýk/koyu tema, vurgu rengi, fiþ detay görünümü.

## Mimari

| Bileþen | Teknoloji | Port |
|---|---|---|
| `services/auth` | Go (gin) | 8081 |
| `services/expense` | Go (gin) | 8082 |
| `services/ocr` | Python 3.11, FastAPI, PaddleOCR | 8083 |
| PostgreSQL | postgres:16 | yalnýzca Docker iç aðý |
| `fissio_mobile/` | Flutter | - |

## Hýzlý baþlangýç

### Backend

```bash
cp .env.example .env        # varsayýlanlar geliþtirme için yeterli
docker compose up --build
```

- Auth: http://localhost:8081/health
- Expense: http://localhost:8082/health
- OCR: http://localhost:8083
- PostgreSQL dýþarý açýlmaz (yalnýzca Docker iç aðý).
- Geliþtirmede e-posta doðrulama kodu SMTP olmadan loga yazýlýr: `docker compose logs auth | grep DEV-OTP`

### Mobil

```bash
cd fissio_mobile
flutter pub get
flutter run
```

Android emülatöründe backend adresi `http://10.0.2.2:8081` (auth), diðer platformlarda `localhost`.

## Mobil kullaným

- **Yeni fiþ (+):** Doðrudan tarama sayfasýný açar. Fiþi taramak istemezseniz tarama ekranýndaki **Manuel** anahtarýyla formu elle doldurabilirsiniz.
- **Fiþ okuma ayarlarý** (Ayarlar > Tercihler > Fiþ okuma):
  - Mod: **Otomatik** (baðlantý varken sunucu, yoksa cihaz), **Sunucu** veya **Cihaz içi** OCR.
  - **Sunucu OCR motoru:** PP-OCRv4 Mobile / Custom OCR.
  - Seçimler kalýcýdýr ve tarama ekranýnda otomatik uygulanýr.
- **Veri yönetimi** (Ayarlar): bulut eþitleme anahtarý, dýþa ve içe aktarma.

## Testler

```bash
# Go servisleri
cd services/auth && go test ./...
cd services/expense && go test ./...

# OCR servisi (imaj içinde)
docker run --rm -v "$(pwd)/services/ocr:/app" -w /app fissio-ocr:latest python -m pytest tests/ -q -p no:cacheprovider

# Mobil
cd fissio_mobile && flutter analyze && flutter test
```

PostgreSQL gerektiren testler `FISSIO_TEST_DATABASE_URL` tanýmlý deðilse atlanýr. Ayrýntýlar için `CLAUDE.md` dosyasýna bakýn.

## Dokümantasyon

- API sözleþmesi: `docs/openapi.yaml`
- Geliþtirici rehberi: `CLAUDE.md`
