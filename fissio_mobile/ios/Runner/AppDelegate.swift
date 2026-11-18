import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
