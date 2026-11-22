import 'package:fissio_mobile/services/launcher_icon.dart';
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

/// Yalnız [badKey] okunurken hata atan depo (ör. tek anahtarda şifre çözme hatası).
class _OneBadKeyStore extends _MemStore {
  _OneBadKeyStore(this.badKey);
  final String badKey;
  @override
  Future<String?> read(String key) => key == badKey ? Future.error(Exception('decrypt')) : super.read(key);
}

class _RecordingLauncher implements LauncherIcon {
  final applied = <String>[];
  @override
  Future<bool> get supported async => true;
  @override
  Future<bool> set(String key) async {
    applied.add(key);
    return true;
  }
}

void main() {
  test('tek anahtar okunamazsa yalnız o tercih varsayılana düşer, diğerleri yüklenir', () async {
    final store = _OneBadKeyStore(ThemeController.styleKey)
      ..map[ThemeController.modeKey] = ThemeMode.dark.name
      ..map[ThemeController.accentKey] = kAccentOptions[1].color.toARGB32().toString()
      ..map[ThemeController.styleKey] = ReceiptStyle.list.name;
    final c = ThemeController(store: store);
    await c.load();
    expect(c.themeMode, ThemeMode.dark);
    expect(c.accent.toARGB32(), kAccentOptions[1].color.toARGB32());
    expect(c.receiptStyle, ReceiptStyle.paper, reason: 'okunamayan anahtar varsayılan');
  });

  testWidgets('başlatıcı ikonu: başka renge dokunup uygulanmış renge dönülürse bekleyen değişiklik iptal edilir',
      (tester) async {
    final launcher = _RecordingLauncher();
    final c = ThemeController(store: _MemStore(), launcherIcon: launcher);
    await c.load();
    await tester.pump();
    final applied = List.of(launcher.applied); // açılışta uygulanan (varsayılan renk)
    final original = c.logoColor;
    final other = kBrandPalette.firstWhere((b) => b.color.toARGB32() != original.toARGB32()).color;
    await c.setLogoColor(other);
    await tester.pump(const Duration(milliseconds: 300));
    await c.setLogoColor(original);
    await tester.pump(const Duration(seconds: 3));
    expect(launcher.applied, applied, reason: 'ara renk uygulanmamalı');
    c.dispose();
  });

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

  test('OCR motorunu göster: varsayılan açık; kapatma kalıcıdır; bozuk değer açık sayılır', () async {
    final store = _MemStore();
    final a = ThemeController(store: store);
    await a.load();
    expect(a.showOcrEngine, isTrue);
    await a.setShowOcrEngine(false);
    expect(store.map[ThemeController.showOcrEngineKey], 'false');

    final b = ThemeController(store: store);
    await b.load();
    expect(b.showOcrEngine, isFalse);

    store.map[ThemeController.showOcrEngineKey] = 'garip';
    final c = ThemeController(store: store);
    await c.load();
    expect(c.showOcrEngine, isTrue, reason: 'yalnızca açıkça "false" kapalıdır');
  });

  test('widget renk teması: varsayılan Sistem; seçim kalıcı; bilinmeyen değer Sistem', () async {
    final store = _MemStore();
    final a = ThemeController(store: store);
    await a.load();
    expect(a.widgetTheme, WidgetTheme.system);
    for (final t in WidgetTheme.values) {
      await a.setWidgetTheme(t);
      final b = ThemeController(store: store);
      await b.load();
      expect(b.widgetTheme, t);
    }
    store.map[ThemeController.widgetThemeKey] = 'neon';
    final c = ThemeController(store: store);
    await c.load();
    expect(c.widgetTheme, WidgetTheme.system);
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

  group('ana sayfa kartları', () {
    test('varsayılan: tüm kartlar görünür, varsayılan sırada', () async {
      final c = ThemeController(store: _MemStore());
      await c.load();
      expect(c.homeCardOrder, HomeCard.values);
      expect(c.hiddenHomeCards, isEmpty);
      expect(c.visibleHomeCards, HomeCard.values);
    });

    test('sıra ve gizleme kaydedilir, yeniden yüklenir; gizli kart görünür listeden çıkar', () async {
      final store = _MemStore();
      final a = ThemeController(store: store);
      await a.setHomeCardOrder([HomeCard.topReceipt, HomeCard.budgets, HomeCard.categories, HomeCard.fixed]);
      await a.setHomeCardHidden(HomeCard.budgets, true);
      expect(a.visibleHomeCards, [HomeCard.topReceipt, HomeCard.categories, HomeCard.fixed]);

      final b = ThemeController(store: store);
      await b.load();
      expect(b.homeCardOrder, [HomeCard.topReceipt, HomeCard.budgets, HomeCard.categories, HomeCard.fixed]);
      expect(b.hiddenHomeCards, {HomeCard.budgets});
      await b.setHomeCardHidden(HomeCard.budgets, false);
      expect(b.hiddenHomeCards, isEmpty);
      await b.resetHomeCards();
      expect(b.homeCardOrder, HomeCard.values);
    });

    test('bozuk/eksik kayıt: bilinmeyen kimlik atılır, tekrar elenir, eksik kart sona eklenir', () async {
      final store = _MemStore()
        ..map[ThemeController.homeCardsKey] = 'fixed,uzay,fixed,topReceipt'
        ..map[ThemeController.homeHiddenKey] = 'uzay,categories';
      final c = ThemeController(store: store);
      await c.load();
      expect(c.homeCardOrder, [HomeCard.fixed, HomeCard.topReceipt, HomeCard.categories, HomeCard.budgets]);
      expect(c.hiddenHomeCards, {HomeCard.categories});
    });

    test('depolama bozukken varsayılanlarla devam eder', () async {
      final c = ThemeController(store: _BrokenStore());
      await c.load();
      await c.setHomeCardHidden(HomeCard.fixed, true); // yazma hatası yutulur
      expect(c.hiddenHomeCards, {HomeCard.fixed});
    });
  });
}
