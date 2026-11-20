import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:home_widget/home_widget.dart';

import 'plugin_log.dart';
import 'share_intent.dart';

/// Ana ekran widget'ındaki hızlı tarama kısayolunun derin bağlantısı (`fissio://scan`).
const kScanDeepLink = 'fissio://scan';

/// Ana ekran widget'ındaki "Dijital Fiş / PDF Ekle" kısayolunun derin bağlantısı (`fissio://import-digital`).
const kImportDeepLink = 'fissio://import-digital';

/// Derin bağlantıyı "bekleyen" olarak tutar; oturum geri yüklenip profil seçildikten sonra ([ShellPage])
/// tüketilir. Soğuk açılışta (uygulama kapalıyken widget'a dokunma) ve sıcak açılışta (arka plandan) çalışır.
///
/// İki istek türü vardır: kamerayla tarama (`fissio://scan`) ve dijital fiş / PDF içe aktarma (`fissio://import-digital`
/// ya da başka uygulamadan "Paylaş → Fissio" ile gelen PDF dosyası; dosya yolu [consumeImport] ile verilir).
class DeepLinkController extends ChangeNotifier {
  bool _pendingScan = false;
  bool _pendingImport = false;
  String? _sharedPath;
  StreamSubscription<Uri?>? _sub;
  StreamSubscription<String>? _fileSub;

  bool get hasPendingScan => _pendingScan;
  bool get hasPendingImport => _pendingImport;

  /// Bekleyen herhangi bir hızlı eylem (açılışta profil seçimi atlansın, splash beklemesin).
  bool get hasPendingAction => _pendingScan || _pendingImport;

  /// Gelen adresi işler (`fissio://scan` ve `fissio://import-digital`).
  void handle(Uri? uri) {
    if (uri == null || uri.scheme != 'fissio') return;
    switch (uri.host) {
      case 'scan':
        _pendingScan = true;
      case 'import-digital':
        _pendingImport = true;
      default:
        return;
    }
    notifyListeners();
  }

  /// Başka uygulamadan paylaşılan/açılan PDF dosyası (yerel yol): dijital fiş akışını bu dosyayla başlatır.
  void handleSharedFile(String? path) {
    if (path == null || path.isEmpty) return;
    _pendingImport = true;
    _sharedPath = path;
    notifyListeners();
  }

  /// Bekleyen tarama isteği varsa true döner ve temizler (tek seferlik).
  bool consumeScan() {
    if (!_pendingScan) return false;
    _pendingScan = false;
    return true;
  }

  /// Bekleyen içe aktarma isteği varsa onu ve (paylaşılan dosya varsa) dosya yolunu döner ve temizler.
  /// Dosya yolu null ise kullanıcıya dosya seçici açılır.
  ({String? path})? consumeImport() {
    if (!_pendingImport) return null;
    final p = _sharedPath;
    _pendingImport = false;
    _sharedPath = null;
    return (path: p);
  }

  /// Soğuk açılış adresini okur ve sıcak açılışları dinler. Eklenti yoksa (test/masaüstü) sessizce geçer.
  Future<void> init({ShareIntentPort? shareIntent}) async {
    if (_sub != null) return;
    try {
      handle(await HomeWidget.initiallyLaunchedFromHomeWidget());
      _sub = HomeWidget.widgetClicked.listen(handle, onError: (Object e) => pluginWarn('Derin bağlantı', e));
    } catch (e) {
      pluginWarn('Derin bağlantı dinlenemedi', e);
    }
    try {
      final port = shareIntent ?? shareIntentPort;
      handleSharedFile(await port.initialFile());
      _fileSub = port.files.listen(handleSharedFile, onError: (Object e) => pluginWarn('Paylaşılan dosya', e));
    } catch (e) {
      pluginWarn('Paylaşılan dosya dinlenemedi', e);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _fileSub?.cancel();
    super.dispose();
  }
}

final deepLinks = DeepLinkController();
