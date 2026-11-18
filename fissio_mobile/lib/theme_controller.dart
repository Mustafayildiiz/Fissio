import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'services/launcher_icon.dart';
import 'theme.dart';

/// Fiş okuma motoru tercihi: otomatik (bağlantı + senkron durumuna göre), sunucu OCR ya da cihaz içi OCR.
enum OcrMode { auto, server, onDevice }

/// Küçük anahtar-değer deposu (testlerde sahtesi verilebilir).
abstract class PrefsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Anahtar silebilen depo (oturum/hesap verisi için). Silemeyen depolarda AppState boş değer yazar.
abstract class DeletablePrefsStore implements PrefsStore {
  Future<void> delete(String key);
}

class SecurePrefsStore implements DeletablePrefsStore {
  const SecurePrefsStore();
  static const _s = FlutterSecureStorage();

  @override
  Future<void> delete(String key) => _s.delete(key: key);

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
}

/// Fiş detayının görünümü.
enum ReceiptStyle { paper, list }

/// Kullanıcının görünüm tercihleri: vurgu rengi, tema modu, fiş detay görünümü, uygulama logosu.
class ThemeController extends ChangeNotifier {
  ThemeController({PrefsStore? store, LauncherIcon? launcherIcon})
    : _store = store ?? const SecurePrefsStore(),
      _launcher = launcherIcon ?? const ChannelLauncherIcon();

  final PrefsStore _store;
  final LauncherIcon _launcher;

  static const accentKey = 'pref_accent';
  static const modeKey = 'pref_theme_mode';
  static const styleKey = 'pref_receipt_style';
  static const ocrModeKey = 'pref_ocr_mode';
  static const ocrEngineKey = 'pref_ocr_engine';
  static const logoKey = 'pref_logo';
  static const launcherKey = 'pref_launcher_icon';

  /// Sunucu OCR motoru (`OcrEngineFactory` anahtarı); tarama ekranı bunu kullanır.
  String ocrEngine = 'paddleocr';
  Color accent = kDefaultAccent;
  ThemeMode themeMode = ThemeMode.system;
  ReceiptStyle receiptStyle = ReceiptStyle.paper;
  OcrMode ocrMode = OcrMode.auto;

  /// Sabit logo rengi; null = logo vurgu rengini (temayı) izler.
  Color? logoOverride;

  /// Uygulama içi logonun ve başlatıcı ikonunun arka plan rengi (tema izlenirken vurgu rengi).
  Color get logoColor => logoOverride ?? accent;
  bool get logoFollowsTheme => logoOverride == null;
  String? _appliedLauncher;
  Timer? _launcherTimer;

  /// `runApp` öncesi çağrılır; depolama okunamazsa varsayılanlarla devam eder.
  Future<void> load() async {
    try {
      final a = await _store.read(accentKey);
      final parsed = a == null ? null : int.tryParse(a);
      if (parsed != null) {
        accent = Color(parsed);
        // Eski varsayılan mor, tasarımdaki mora taşınır (swatch seçili görünsün).
        if (accent.toARGB32() == kLegacyPurple.toARGB32()) accent = kBrandPurple;
      }
      final lg = await _store.read(logoKey);
      final lgParsed = lg == null ? null : int.tryParse(lg);
      logoOverride = lgParsed == null ? null : Color(lgParsed);
      _appliedLauncher = await _store.read(launcherKey);
      final m = await _store.read(modeKey);
      themeMode = ThemeMode.values.firstWhere(
        (e) => e.name == m,
        orElse: () => ThemeMode.system,
      );
      final s = await _store.read(styleKey);
      receiptStyle = ReceiptStyle.values.firstWhere(
        (e) => e.name == s,
        orElse: () => ReceiptStyle.paper,
      );
      final o = await _store.read(ocrModeKey);
      ocrMode = OcrMode.values.firstWhere((e) => e.name == o, orElse: () => OcrMode.auto);
      final e = await _store.read(ocrEngineKey);
      if (e != null && e.isNotEmpty) ocrEngine = e;
    } catch (_) {
      // Depolama yoksa (test/ilk açılış) varsayılanlar geçerli.
    }
    notifyListeners();
    unawaited(_syncLauncher(debounce: false));
  }

  Future<void> setAccent(Color c) async {
    accent = c;
    notifyListeners();
    await _save(accentKey, c.toARGB32().toString());
    unawaited(_syncLauncher());
  }

  /// Logo rengini ayarlar; null = temayı (vurgu rengini) izle. Başlatıcı ikonu da buna göre değişir.
  Future<void> setLogoColor(Color? c) async {
    logoOverride = c;
    notifyListeners();
    await _save(logoKey, c == null ? 'theme' : c.toARGB32().toString());
    unawaited(_syncLauncher());
  }

  /// Platform ana ekran ikonunu uygulama içinden değiştirebiliyor mu (Android'de yalnızca yayın sürümleri).
  Future<bool> get launcherSupported async {
    try {
      return await _launcher.supported;
    } catch (_) {
      return false;
    }
  }

  /// Başlatıcı (launcher) ikonunu [logoColor]'a eşitler. Platform desteklemiyorsa (test/masaüstü) hiçbir şey
  /// yapmaz. Swatch'lara art arda dokunulurken ikon sürekli değişmesin diye kısa gecikmeyle birleştirilir.
  Future<void> _syncLauncher({bool debounce = true}) async {
    try {
      if (!await _launcher.supported) return;
      final key = brandKeyOf(logoColor);
      if (key == _appliedLauncher) return;
      Future<void> apply() async {
        if (await _launcher.set(key)) {
          _appliedLauncher = key;
          await _save(launcherKey, key);
        }
      }

      _launcherTimer?.cancel();
      if (!debounce) return await apply();
      _launcherTimer = Timer(const Duration(milliseconds: 1500), apply);
    } catch (_) {}
  }

  @override
  void dispose() {
    _launcherTimer?.cancel();
    super.dispose();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    notifyListeners();
    await _save(modeKey, m.name);
  }

  Future<void> setReceiptStyle(ReceiptStyle s) async {
    receiptStyle = s;
    notifyListeners();
    await _save(styleKey, s.name);
  }

  Future<void> setOcrMode(OcrMode m) async {
    ocrMode = m;
    notifyListeners();
    await _save(ocrModeKey, m.name);
  }

  Future<void> setOcrEngine(String e) async {
    ocrEngine = e;
    notifyListeners();
    await _save(ocrEngineKey, e);
  }

  Future<void> _save(String key, String value) async {
    try {
      await _store.write(key, value);
    } catch (_) {}
  }
}

final themeController = ThemeController();
