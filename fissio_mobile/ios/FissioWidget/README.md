# Fissio iOS ana ekran widget'ları (doğrulanmadı)

`FissioWidget.swift` WidgetKit kaynağıdır ve **4 widget** içerir (`FissioWidgetBundle`): toplam + "Fiş tara" +
"Dijital fiş" (`FissioWidget`), yalnızca "Fiş tara" (`FissioScanWidget`), yalnızca "Dijital fiş"
(`FissioDigitalWidget`) ve ikili kısayol (`FissioCombinedWidget`). Hepsi `fissio_widget_theme` /
`fissio_widget_accent` (App Group) ile Tercihler > Widget renk temasını uygular; `WidgetKeys.providers` (Dart) bu
dört `kind` adını yeniden çizdirir. **Xcode hedefine henüz bağlı değildir** ve bu repo Windows'ta
geliştirildiği için iOS tarafı derlenip denenmemiştir. Android widget'ı (`android/.../FissioWidgetProvider.kt`)
tamamlanmış ve derlenmiştir.

Bağlamak için (Mac + Xcode):

1. Xcode'da `Runner.xcworkspace` > File > New > Target > **Widget Extension**, adı `FissioWidget`
   (Include Configuration App Intent: kapalı). Oluşan örnek Swift dosyalarını silip bu klasördeki
   `FissioWidget.swift` dosyasını hedefe ekleyin.
2. `Runner` ve `FissioWidget` hedeflerinde **Signing & Capabilities > App Groups** ekleyip
   `group.com.example.fissioMobile` grubunu (lib/services/widget_sync.dart `WidgetKeys.appGroup`) seçin.
3. Uygulama bundle kimliğini değiştirirseniz hem App Group'u hem `WidgetKeys.appGroup` ve
   `FissioWidget.swift` içindeki `appGroup` sabitini güncelleyin.
4. `fissio://` şeması `Runner/Info.plist` içinde (`CFBundleURLTypes`) tanımlıdır; widget'taki
   "Fiş tara" (`fissio://scan?homeWidget`) ve "Dijital fiş" (`fissio://import-digital?homeWidget`) bağlantıları
   uygulamayı doğrudan ilgili akışta açar, `home_widget` adresi Dart'a iletir (`lib/services/deep_links.dart`).
   (`?homeWidget` sorgusu olmayan adresleri `home_widget` yok sayar.)
5. Alternatif ana ekran simgeleri (`Assets.xcassets/AppIcon-<renk>.appiconset` +
   `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`) da Xcode'da derlenerek doğrulanmalıdır.
6. **Dijital fiş (PDF) — iOS notları:** `Runner/Info.plist` `CFBundleDocumentTypes` (PDF, "Fissio ile aç") ve
   `AppDelegate.swift` (`application(_:open:)`, `fissio/pdf` + `fissio/share_intent` köprüleri, PDFKit) yazıldı ama
   Windows'ta derlenemedi. **Paylaş sayfasında (Share Sheet) görünmek için** ayrıca bir *Share Extension* Xcode hedefi
   gerekir; kapsam dışıdır (şimdilik Dosyalar/Mail'de "Fissio ile aç" çalışır).
