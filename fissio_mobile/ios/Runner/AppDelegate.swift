import Flutter
import PDFKit
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// "Birlikte aç / Paylaş → Fissio" ile gelen PDF'in yerel kopyası (soğuk açılışta Dart `getInitialFile` ile okur).
  private var pendingSharedFile: String?
  private var shareChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Uygulama açıkken de yerel bildirimler (bütçe uyarısı / ödeme hatırlatıcısı) gösterilsin.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerLauncherIconChannel(engineBridge.pluginRegistry)
    registerPdfChannel(engineBridge.pluginRegistry)
    registerShareChannel(engineBridge.pluginRegistry)
  }

  // MARK: - Dijital fiş (PDF / .eml / HTML)

  /// Başka uygulamadan açılan PDF, .eml e-posta ya da HTML sipariş özeti (Dosyalar, Mail, WhatsApp "Birlikte aç"): uygulama
  /// önbelleğine KAYNAĞIN UZANTISIYLA kopyalanır (Dart tarafı dosyayı uzantısına göre ayrıştırır) ve yerel yol
  /// Dart'a iletilir. Dosya hiçbir yere gönderilmez. DİKKAT: Share Extension (Paylaş sayfasında görünme) Xcode hedefi
  /// gerektirir ve burada YOK; "Birlikte aç" Info.plist CFBundleDocumentTypes ile çalışır. Windows'ta derlenip doğrulanamaz.
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.isFileURL, Self.sharedExtensions.contains(url.pathExtension.lowercased()), let path = copyToCache(url) {
      if let ch = shareChannel {
        ch.invokeMethod("onFile", arguments: path)
      } else {
        pendingSharedFile = path
      }
      return true
    }
    return super.application(app, open: url, options: options)
  }

  /// Kabul edilen uzantılar (Info.plist CFBundleDocumentTypes ile aynı küme); `htm` → `html` olarak saklanır.
  private static let sharedExtensions: Set<String> = ["pdf", "eml", "html", "htm"]

  private func copyToCache(_ url: URL) -> String? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20 * 1024 * 1024 else { return nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shared", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ext = url.pathExtension.lowercased() == "htm" ? "html" : url.pathExtension.lowercased()
    let dest = dir.appendingPathComponent("shared_\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)")
    do {
      try FileManager.default.copyItem(at: url, to: dest)
      return dest.path
    } catch {
      return nil
    }
  }

  private func registerShareChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "FissioShareIntent") else { return }
    let channel = FlutterMethodChannel(name: "fissio/share_intent", binaryMessenger: registrar.messenger())
    shareChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "getInitialFile" {
        let path = self?.pendingSharedFile
        self?.pendingSharedFile = nil
        result(path)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// PDF okuyucu köprüsü (lib/services/pdf_reader.dart): `readText` (PDFKit metin katmanı) ve `renderPages` (PNG).
  private func registerPdfChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "FissioPdf") else { return }
    let channel = FlutterMethodChannel(name: "fissio/pdf", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "bad_path", message: "PDF dosyası bulunamadı", details: nil))
        return
      }
      let maxPages = args["maxPages"] as? Int ?? 6
      DispatchQueue.global(qos: .userInitiated).async {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
          DispatchQueue.main.async { result(FlutterError(code: "read_failed", message: "PDF açılamadı", details: nil)) }
          return
        }
        if doc.isLocked {
          DispatchQueue.main.async { result(FlutterError(code: "encrypted", message: "PDF parola korumalı", details: nil)) }
          return
        }
        let count = min(doc.pageCount, maxPages)
        switch call.method {
        case "readText":
          let texts = (0..<count).map { doc.page(at: $0)?.string ?? "" }
          DispatchQueue.main.async { result(texts) }
        case "renderPages":
          var pages: [FlutterStandardTypedData] = []
          for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 1600.0 / max(bounds.width, bounds.height)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if let png = page.thumbnail(of: size, for: .mediaBox).pngData() {
              pages.append(FlutterStandardTypedData(bytes: png))
            }
          }
          DispatchQueue.main.async { result(pages) }
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        }
      }
    }
  }

  /// Uygulama içinden ana ekran ikonu seçimi (lib/services/launcher_icon.dart). 'red' varsayılan ikondur;
  /// diğer renkler Assets.xcassets/AppIcon-<renk>.appiconset (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES).
  private func registerLauncherIconChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "FissioLauncherIcon") else { return }
    let channel = FlutterMethodChannel(name: "fissio/launcher_icon", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "supported":
        result(UIApplication.shared.supportsAlternateIcons)
      case "set":
        guard let args = call.arguments as? [String: Any], let key = args["key"] as? String else {
          result(FlutterError(code: "bad_key", message: "key gerekli", details: nil))
          return
        }
        UIApplication.shared.setAlternateIconName(key == "red" ? nil : "AppIcon-\(key)") { error in
          result(error == nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
