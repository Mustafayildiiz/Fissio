# fissio_mobile

Fissio'nun Flutter mobil uygulaması (Android/iOS). Proje özeti, backend kurulumu ve mimari için kök dizindeki [README.md](../README.md) ve [CLAUDE.md](../CLAUDE.md) dosyalarına bakın.

```bash
flutter pub get
flutter run                                   # Android emülatörü: backend http://10.0.2.2:8081 / :8082
flutter run --dart-define=API_HOST=192.168.x.x   # gerçek cihaz
flutter build apk --release --dart-define=API_BASE=https://api.ornek.com   # yayın: tek origin, yalnızca HTTPS
flutter analyze && flutter test               # testler ../testdata altın vektörlerini okur
```

- Düz HTTP yalnızca debug/profile derlemelerinde açıktır (`android/app/src/{debug,profile}/AndroidManifest.xml`).
- Yayın imzası: `android/key.properties` (örnek: `android/key.properties.example`); yoksa release debug anahtarıyla imzalanır.
- `dart format` kullanmayın: kod ~100 sütunla yazılmıştır ve formatter yapılandırması yoktur.
