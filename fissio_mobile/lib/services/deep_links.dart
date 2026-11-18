import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:home_widget/home_widget.dart';

import 'plugin_log.dart';

/// Ana ekran widget'ındaki hızlı tarama kısayolunun derin bağlantısı (`fissio://scan`).
const kScanDeepLink = 'fissio://scan';

/// Derin bağlantıyı "bekleyen" olarak tutar; oturum geri yüklenip profil seçildikten sonra ([ShellPage])
/// tüketilir. Soğuk açılışta (uygulama kapalıyken widget'a dokunma) ve sıcak açılışta (arka plandan) çalışır.
class DeepLinkController extends ChangeNotifier {
  bool _pendingScan = false;
  StreamSubscription<Uri?>? _sub;

  bool get hasPendingScan => _pendingScan;

  /// Gelen adresi işler (yalnızca `fissio://scan`).
  void handle(Uri? uri) {
    if (uri == null || uri.scheme != 'fissio' || uri.host != 'scan') return;
    _pendingScan = true;
    notifyListeners();
  }

  /// Bekleyen tarama isteği varsa true döner ve temizler (tek seferlik).
  bool consumeScan() {
    if (!_pendingScan) return false;
    _pendingScan = false;
    return true;
  }

  /// Soğuk açılış adresini okur ve sıcak açılışları dinler. Eklenti yoksa (test/masaüstü) sessizce geçer.
  Future<void> init() async {
    if (_sub != null) return;
    try {
      handle(await HomeWidget.initiallyLaunchedFromHomeWidget());
      _sub = HomeWidget.widgetClicked.listen(handle, onError: (Object e) => pluginWarn('Derin bağlantı', e));
    } catch (e) {
      pluginWarn('Derin bağlantı dinlenemedi', e);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final deepLinks = DeepLinkController();
