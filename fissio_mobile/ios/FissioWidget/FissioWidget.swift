import SwiftUI
import WidgetKit

// Fissio ana ekran widget'ları (iOS, WidgetKit) — 4 widget:
//   1. FissioWidget          : aktif profilin "Bu ayki toplam harcaması" + "Fiş tara" + "Dijital fiş" kısayolları
//   2. FissioScanWidget      : yalnızca "Fiş tara"      → fissio://scan?homeWidget
//   3. FissioDigitalWidget   : yalnızca "Dijital fiş"   → fissio://import-digital?homeWidget
//   4. FissioCombinedWidget  : iki kısayol yan yana
// Veri Flutter tarafından `home_widget` ile App Group UserDefaults'a yazılır (anahtarlar lib/services/widget_sync.dart
// -> WidgetKeys). Renk teması (Sistem/Açık/Koyu/Marka) `fissio_widget_theme` + marka rengi `fissio_widget_accent`
// (#AARRGGBB) anahtarlarından okunur; tercih değişince uygulama WidgetCenter.reloadTimelines çağırır (home_widget
// updateWidget, her widget `kind` için).
//
// DİKKAT: Bu dosya Xcode hedefine henüz bağlı DEĞİLDİR ve Windows'ta derlenip doğrulanamaz.

private let appGroup = "group.com.example.fissioMobile"
private let defaultBrand = Color(red: 0xEC / 255, green: 0x30 / 255, blue: 0x13 / 255)

// MARK: - Tema

enum FissioTheme: String {
  case system, light, dark, brand
}

struct FissioStyle {
  var theme: FissioTheme
  var accent: Color

  static func read() -> FissioStyle {
    let d = UserDefaults(suiteName: appGroup)
    let theme = FissioTheme(rawValue: d?.string(forKey: "fissio_widget_theme") ?? "") ?? .system
    let accent = Color(hex: d?.string(forKey: "fissio_widget_accent")) ?? defaultBrand
    return FissioStyle(theme: theme, accent: accent)
  }

  /// Zemin: system = sistem yüzeyi (açık/koyu otomatik), light/dark sabit, brand = marka rengi.
  var background: Color {
    switch theme {
    case .system: return Color(.systemBackground)
    case .light: return .white
    case .dark: return Color(red: 0x1F / 255, green: 0x1D / 255, blue: 0x1C / 255)
    case .brand: return accent
    }
  }

  var ink: Color {
    switch theme {
    case .system: return .primary
    case .light: return Color(red: 0x20 / 255, green: 0x1E / 255, blue: 0x1D / 255)
    case .dark: return Color(red: 0xF3 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)
    case .brand: return .white
    }
  }

  var mute: Color {
    switch theme {
    case .system: return .secondary
    case .light: return Color(red: 0x60 / 255, green: 0x5D / 255, blue: 0x5D / 255)
    case .dark: return Color(red: 0x9B / 255, green: 0x97 / 255, blue: 0x97 / 255)
    case .brand: return Color.white.opacity(0.8)
    }
  }

  /// Eylem düğmesi: brand'de beyaz zemin + marka renkli yazı; diğerlerinde marka renkli zemin + beyaz yazı.
  var buttonBackground: Color { theme == .brand ? .white : defaultBrand }
  var buttonForeground: Color { theme == .brand ? accent : .white }
}

extension Color {
  /// `#AARRGGBB` / `#RRGGBB`; geçersizse nil.
  init?(hex: String?) {
    guard var h = hex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return nil }
    h.removeFirst()
    guard let v = UInt64(h, radix: 16) else { return nil }
    let a: Double, r: Double, g: Double, b: Double
    if h.count == 8 {
      a = Double((v >> 24) & 0xFF) / 255; r = Double((v >> 16) & 0xFF) / 255
      g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
    } else if h.count == 6 {
      a = 1; r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
    } else {
      return nil
    }
    self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
  }
}

private func widgetBackground(_ style: FissioStyle) -> some View {
  style.background
}

// MARK: - Ortak parçalar

struct ShortcutButton: View {
  let style: FissioStyle
  let symbol: String
  let title: String
  let url: String

  var body: some View {
    Link(destination: URL(string: url)!) {
      HStack(spacing: 6) {
        Image(systemName: symbol)
        Text(title).fontWeight(.bold)
      }
      .font(.system(size: 14))
      .foregroundColor(style.buttonForeground)
      .frame(maxWidth: .infinity, minHeight: 36)
      .background(style.buttonBackground)
      .cornerRadius(12)
    }
  }
}

private let scanURL = "fissio://scan?homeWidget"
private let importURL = "fissio://import-digital?homeWidget"

// MARK: - 1. Toplam + kısayollar

struct FissioEntry: TimelineEntry {
  let date: Date
  let signedIn: Bool
  let profile: String
  let total: String
  let month: String
  let style: FissioStyle
}

struct FissioProvider: TimelineProvider {
  private func current() -> FissioEntry {
    let d = UserDefaults(suiteName: appGroup)
    return FissioEntry(
      date: Date(),
      signedIn: d?.bool(forKey: "fissio_signed_in") ?? false,
      profile: d?.string(forKey: "fissio_profile") ?? "",
      total: d?.string(forKey: "fissio_month_total") ?? "",
      month: d?.string(forKey: "fissio_month_label") ?? "",
      style: FissioStyle.read()
    )
  }

  func placeholder(in context: Context) -> FissioEntry {
    FissioEntry(date: Date(), signedIn: true, profile: "Kişisel", total: "1.250,00 ₺", month: "Kasım 2026", style: FissioStyle(theme: .system, accent: defaultBrand))
  }

  func getSnapshot(in context: Context, completion: @escaping (FissioEntry) -> Void) {
    completion(current())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<FissioEntry>) -> Void) {
    // Uygulama veriyi/temayı her değişimde yazar ve WidgetCenter.reloadTimelines çağırır (home_widget updateWidget).
    completion(Timeline(entries: [current()], policy: .never))
  }
}

struct FissioWidgetView: View {
  var entry: FissioEntry

  var body: some View {
    let style = entry.style
    VStack(alignment: .leading, spacing: 4) {
      Text("BU AYKİ HARCAMA").font(.system(size: 11, weight: .bold)).foregroundColor(style.mute)
      if entry.signedIn && !entry.total.isEmpty {
        Text(entry.total).font(.system(size: 26, weight: .heavy)).foregroundColor(style.ink).minimumScaleFactor(0.6).lineLimit(1)
        Text([entry.profile, entry.month].filter { !$0.isEmpty }.joined(separator: " · "))
          .font(.system(size: 12)).foregroundColor(style.mute).lineLimit(1)
      } else {
        Text("Giriş yapın").font(.system(size: 22, weight: .heavy)).foregroundColor(style.ink)
      }
      Spacer(minLength: 0)
      if entry.signedIn {
        // Hızlı eylemler: uygulamayı doğrudan tarama / dijital fiş akışında açar.
        HStack(spacing: 8) {
          ShortcutButton(style: style, symbol: "doc.viewfinder", title: "Fiş tara", url: scanURL)
          ShortcutButton(style: style, symbol: "doc.text", title: "Dijital fiş", url: importURL)
        }
      }
    }
    .padding(14)
    .widgetURL(URL(string: "fissio://home"))
  }
}

struct FissioWidget: Widget {
  let kind = "FissioWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: FissioProvider()) { entry in
      themed(FissioWidgetView(entry: entry), style: entry.style)
    }
    .configurationDisplayName("Fissio")
    .description("Bu ayki toplam harcaman, hızlı fiş tarama ve dijital fiş ekleme.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

// MARK: - 2-4. Yalnızca kısayol widget'ları

struct ShortcutEntry: TimelineEntry {
  let date: Date
  let style: FissioStyle
}

struct ShortcutProvider: TimelineProvider {
  func placeholder(in context: Context) -> ShortcutEntry { ShortcutEntry(date: Date(), style: FissioStyle(theme: .system, accent: defaultBrand)) }
  func getSnapshot(in context: Context, completion: @escaping (ShortcutEntry) -> Void) { completion(ShortcutEntry(date: Date(), style: FissioStyle.read())) }
  func getTimeline(in context: Context, completion: @escaping (Timeline<ShortcutEntry>) -> Void) {
    completion(Timeline(entries: [ShortcutEntry(date: Date(), style: FissioStyle.read())], policy: .never))
  }
}

struct FissioScanWidgetView: View {
  var entry: ShortcutEntry
  var body: some View {
    ShortcutButton(style: entry.style, symbol: "doc.viewfinder", title: "Fiş Tara", url: scanURL).padding(10)
  }
}

struct FissioDigitalWidgetView: View {
  var entry: ShortcutEntry
  var body: some View {
    ShortcutButton(style: entry.style, symbol: "doc.text", title: "Dijital Fiş", url: importURL).padding(10)
  }
}

struct FissioCombinedWidgetView: View {
  var entry: ShortcutEntry
  var body: some View {
    HStack(spacing: 8) {
      ShortcutButton(style: entry.style, symbol: "doc.viewfinder", title: "Fiş Tara", url: scanURL)
      ShortcutButton(style: entry.style, symbol: "doc.text", title: "Dijital Fiş", url: importURL)
    }
    .padding(10)
  }
}

struct FissioScanWidget: Widget {
  let kind = "FissioScanWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: ShortcutProvider()) { entry in
      themed(FissioScanWidgetView(entry: entry), style: entry.style)
    }
    .configurationDisplayName("Fiş Tara")
    .description("Kamerayla hızlı fiş tarama kısayolu.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct FissioDigitalWidget: Widget {
  let kind = "FissioDigitalWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: ShortcutProvider()) { entry in
      themed(FissioDigitalWidgetView(entry: entry), style: entry.style)
    }
    .configurationDisplayName("Dijital Fiş")
    .description("Dijital fiş / PDF ekleme kısayolu.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct FissioCombinedWidget: Widget {
  let kind = "FissioCombinedWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: ShortcutProvider()) { entry in
      themed(FissioCombinedWidgetView(entry: entry), style: entry.style)
    }
    .configurationDisplayName("Fiş + Dijital Fiş")
    .description("Fiş tara ve dijital fiş ekle kısayolları yan yana.")
    .supportedFamilies([.systemMedium])
  }
}

/// iOS 17+ `containerBackground`, öncesinde `background`; zemin renk temasından gelir.
@ViewBuilder
private func themed<V: View>(_ view: V, style: FissioStyle) -> some View {
  if #available(iOS 17.0, *) {
    view.containerBackground(style.background, for: .widget)
  } else {
    view.background(style.background)
  }
}

@main
struct FissioWidgetBundle: WidgetBundle {
  var body: some Widget {
    FissioWidget()
    FissioScanWidget()
    FissioDigitalWidget()
    FissioCombinedWidget()
  }
}
