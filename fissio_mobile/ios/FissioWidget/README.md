# Fissio iOS ana ekran widget'ı (doğrulanmadı)

`FissioWidget.swift` WidgetKit kaynağıdır; **Xcode hedefine henüz bağlı değildir** ve bu repo Windows'ta
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
4. `fissio://scan` şeması `Runner/Info.plist` içinde (`CFBundleURLTypes`) tanımlıdır; widget'taki
   "Fiş tara" bağlantısı uygulamayı bu adresle açar, `home_widget` adresi Dart'a iletir
   (`lib/services/deep_links.dart`).
5. Alternatif ana ekran simgeleri (`Assets.xcassets/AppIcon-<renk>.appiconset` +
   `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`) da Xcode'da derlenerek doğrulanmalıdır.
