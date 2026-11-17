import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

/// Kullanıcının görünüm tercihleri: vurgu rengi, tema modu, fiş detay görünümü.
class ThemeController extends ChangeNotifier {
  ThemeController({PrefsStore? store}) : _store = store ?? const SecurePrefsStore();

  final PrefsStore _store;

  static const accentKey = 'pref_accent';
  static const modeKey = 'pref_theme_mode';
  static const styleKey = 'pref_receipt_style';
  static const ocrModeKey = 'pref_ocr_mode';

  Color accent = kDefaultAccent;
  ThemeMode themeMode = ThemeMode.system;
  ReceiptStyle receiptStyle = ReceiptStyle.paper;
  OcrMode ocrMode = OcrMode.auto;

  /// `runApp` öncesi çağrılır; depolama okunamazsa varsayılanlarla devam eder.
  Future<void> load() async {
    try {
      final a = await _store.read(accentKey);
      final parsed = a == null ? null : int.tryParse(a);
      if (parsed != null) accent = Color(parsed);
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
    } catch (_) {
      // Depolama yoksa (test/ilk açılış) varsayılanlar geçerli.
    }
    notifyListeners();
  }

  Future<void> setAccent(Color c) async {
    accent = c;
    notifyListeners();
    await _save(accentKey, c.toARGB32().toString());
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

  Future<void> _save(String key, String value) async {
    try {
      await _store.write(key, value);
    } catch (_) {}
  }
}

final themeController = ThemeController();
