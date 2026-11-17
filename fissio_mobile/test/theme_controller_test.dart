import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemStore implements PrefsStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

class _BrokenStore implements PrefsStore {
  @override
  Future<String?> read(String key) => throw Exception('no storage');
  @override
  Future<void> write(String key, String value) => throw Exception('no storage');
}

void main() {
  test('varsayılanlar: mor vurgu, sistem teması, kağıt fiş', () async {
    final c = ThemeController(store: _MemStore());
    await c.load();
    expect(c.accent, kDefaultAccent);
    expect(c.themeMode, ThemeMode.system);
    expect(c.receiptStyle, ReceiptStyle.paper);
  });

  test('tercihler kaydedilir ve yeniden yüklenir', () async {
    final store = _MemStore();
    final a = ThemeController(store: store);
    await a.setAccent(kAccentOptions[1].color);
    await a.setThemeMode(ThemeMode.dark);
    await a.setReceiptStyle(ReceiptStyle.list);

    final b = ThemeController(store: store);
    await b.load();
    expect(b.accent.toARGB32(), kAccentOptions[1].color.toARGB32());
    expect(b.themeMode, ThemeMode.dark);
    expect(b.receiptStyle, ReceiptStyle.list);
  });

  test('depolama hata verirse varsayılanlarla devam eder', () async {
    final c = ThemeController(store: _BrokenStore());
    await c.load();
    await c.setThemeMode(ThemeMode.light); // yazma hatası yutulur
    expect(c.themeMode, ThemeMode.light);
    expect(c.accent, kDefaultAccent);
  });

  test('buildTheme açık/koyu için FissioColors taşır; yüzeyler vurgudan tonlanmaz', () {
    for (final b in Brightness.values) {
      final t = buildTheme(brightness: b, accent: kAccentOptions[1].color);
      final c = t.extension<FissioColors>()!;
      expect(c.isDark, b == Brightness.dark);
      expect(c.accent, kAccentOptions[1].color);
      expect(t.colorScheme.surfaceTint, Colors.transparent);
      expect(t.colorScheme.surfaceContainerHigh, c.surf);
      expect(t.scaffoldBackgroundColor, c.bg);
    }
  });
}
