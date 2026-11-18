import SwiftUI
import WidgetKit

// Fissio ana ekran widget'ı (iOS, WidgetKit): aktif profilin "Bu ayki toplam harcaması" ve hızlı tarama kısayolu.
// Veri Flutter tarafından `home_widget` ile App Group UserDefaults'a yazılır
// (anahtarlar lib/services/widget_sync.dart -> WidgetKeys). Kurulum adımları için FissioWidget/README.md.
//
// DİKKAT: Bu dosya Xcode hedefine henüz bağlı DEĞİLDİR ve Windows'ta derlenip doğrulanamaz.

private let appGroup = "group.com.example.fissioMobile"

struct FissioEntry: TimelineEntry {
  let date: Date
  let signedIn: Bool
  let profile: String
  let total: String
  let month: String
}

struct FissioProvider: TimelineProvider {
  private func current() -> FissioEntry {
    let d = UserDefaults(suiteName: appGroup)
    return FissioEntry(
      date: Date(),
      signedIn: d?.bool(forKey: "fissio_signed_in") ?? false,
      profile: d?.string(forKey: "fissio_profile") ?? "",
      total: d?.string(forKey: "fissio_month_total") ?? "",
      month: d?.string(forKey: "fissio_month_label") ?? ""
    )
  }

  func placeholder(in context: Context) -> FissioEntry {
    FissioEntry(date: Date(), signedIn: true, profile: "Kişisel", total: "1.250,00 ₺", month: "Kasım 2026")
  }

  func getSnapshot(in context: Context, completion: @escaping (FissioEntry) -> Void) {
    completion(current())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<FissioEntry>) -> Void) {
    // Uygulama veriyi her değişimde yazar ve WidgetCenter.reloadTimelines çağırır (home_widget updateWidget).
    completion(Timeline(entries: [current()], policy: .never))
  }
}

struct FissioWidgetView: View {
  var entry: FissioEntry
  private let brand = Color(red: 0xEC / 255, green: 0x30 / 255, blue: 0x13 / 255)

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("BU AYKİ HARCAMA").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
      if entry.signedIn && !entry.total.isEmpty {
        Text(entry.total).font(.system(size: 26, weight: .heavy)).minimumScaleFactor(0.6).lineLimit(1)
        Text([entry.profile, entry.month].filter { !$0.isEmpty }.joined(separator: " · "))
          .font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
      } else {
        Text("Giriş yapın").font(.system(size: 22, weight: .heavy))
      }
      Spacer(minLength: 0)
      if entry.signedIn {
        // Hızlı tara: uygulamayı doğrudan tarama ekranında açar (fissio://scan).
        Link(destination: URL(string: "fissio://scan")!) {
          HStack(spacing: 6) {
            Image(systemName: "doc.viewfinder")
            Text("Fiş tara").fontWeight(.bold)
          }
          .font(.system(size: 14))
          .foregroundColor(.white)
          .frame(maxWidth: .infinity, minHeight: 36)
          .background(brand)
          .cornerRadius(12)
        }
      }
    }
    .padding(14)
    .widgetURL(URL(string: "fissio://home"))
  }
}

@main
struct FissioWidget: Widget {
  let kind = "FissioWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: FissioProvider()) { entry in
      if #available(iOS 17.0, *) {
        FissioWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
      } else {
        FissioWidgetView(entry: entry).background(Color(.systemBackground))
      }
    }
    .configurationDisplayName("Fissio")
    .description("Bu ayki toplam harcaman ve hızlı fiş tarama.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
