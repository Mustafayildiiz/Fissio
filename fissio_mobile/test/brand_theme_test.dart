import 'package:fissio_mobile/logo.dart';
import 'package:fissio_mobile/pages/preferences_page.dart';
import 'package:fissio_mobile/services/deep_links.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _MemStore implements PrefsStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

void main() {
  group('Fissio Logo Final paleti', () {
    test('tasarımdaki 7 renk hem vurgu hem logo/ikon rengi olarak tanımlı', () {
      const design = {
        'ink': 0xFF201E1D,
        'graphite': 0xFF3A3736,
        'red': 0xFFEC3013,
        'purple': 0xFF5B3FD1,
        'green': 0xFF1F8A4C,
        'darkred': 0xFFAE1800,
        'blue': 0xFF1F5FD1,
      };
      expect({for (final p in kBrandPalette) p.key: p.color.toARGB32()}, design);
      expect({for (final a in kAccentOptions) a.color.toARGB32()}, design.values.toSet());
      // Eski seçeneklerin sırası korunur (kayıtlı tercihler/testler).
      expect(kAccentOptions.take(4).map((a) => a.name), ['Mor', 'Yeşil', 'Koyu kırmızı', 'Kırmızı']);
      expect(brandKeyOf(const Color(0xFF1F5FD1)), 'blue');
      expect(brandKeyOf(const Color(0xFF123456)), 'red', reason: 'palet dışı renk varsayılan ikona düşer');
    });

    test('varsayılan vurgu tasarım sisteminin marka rengi', () {
      expect(kDefaultAccent, const Color(0xFFEC3013));
    });

    test('koyu temada neredeyse siyah vurgular görünür dolgu alır, üstündeki metin okunur kalır', () {
      for (final dark in [const Color(0xFF201E1D), const Color(0xFF3A3736)]) {
        final c = FissioColors.dark(dark);
        expect(c.accent.computeLuminance(), greaterThan(.5), reason: 'dolgu zeminden ayrışmalı');
        expect(c.accentInk.computeLuminance(), greaterThan(.5));
        expect(c.onAccent.computeLuminance(), lessThan(.1), reason: 'açık dolgu üstünde koyu metin');
        // Açık temada seçilen renk aynen dolgudur, metin beyaz.
        final l = FissioColors.light(dark);
        expect(l.accent, dark);
        expect(l.onAccent, Colors.white);
      }
      // Diğer vurgular koyu temada da birebir korunur.
      for (final o in kAccentOptions.where((o) => o.color.computeLuminance() >= .08)) {
        expect(FissioColors.dark(o.color).accent, o.color);
        expect(FissioColors.dark(o.color).onAccent, Colors.white);
      }
    });

    test('bütçe uyarı (sarı) ve kritik (kırmızı) renkleri iki temada da tanımlı ve birbirinden farklı', () {
      for (final c in [FissioColors.light(), FissioColors.dark()]) {
        expect(c.warn, isNot(c.danger));
        expect(c.warn, isNot(c.accent));
        // Sarı: kırmızı ve yeşil kanalları yüksek, mavi düşük.
        expect(c.warn.r, greaterThan(.8));
        expect(c.warn.g, greaterThan(.55));
        expect(c.warn.b, lessThan(.4));
      }
    });
  });

  group('tema denetleyicisi: logo ve başlatıcı ikonu', () {
    test('varsayılan: logo temayı (vurguyu) izler', () async {
      final c = ThemeController(store: _MemStore(), launcherIcon: FakeLauncherIcon(isSupported: false));
      await c.load();
      expect(c.logoFollowsTheme, isTrue);
      expect(c.logoColor, c.accent);
      await c.setAccent(const Color(0xFF1F5FD1));
      expect(c.logoColor, const Color(0xFF1F5FD1), reason: 'tema izlenirken logo vurguyla değişir');
    });

    test('sabit logo rengi kaydedilir, yeniden yüklenir ve vurgudan bağımsızdır', () async {
      final store = _MemStore();
      final a = ThemeController(store: store, launcherIcon: FakeLauncherIcon(isSupported: false));
      await a.setAccent(const Color(0xFF1F8A4C));
      await a.setLogoColor(const Color(0xFF3A3736));
      expect(a.logoFollowsTheme, isFalse);
      expect(a.logoColor, const Color(0xFF3A3736));

      final b = ThemeController(store: store, launcherIcon: FakeLauncherIcon(isSupported: false));
      await b.load();
      expect(b.accent, const Color(0xFF1F8A4C));
      expect(b.logoColor, const Color(0xFF3A3736));

      await b.setLogoColor(null); // temaya dön
      final c = ThemeController(store: store, launcherIcon: FakeLauncherIcon(isSupported: false));
      await c.load();
      expect(c.logoFollowsTheme, isTrue);
      expect(c.logoColor, const Color(0xFF1F8A4C));
    });

    test('eski varsayılan mor tasarımdaki mora taşınır', () async {
      final store = _MemStore()..map[ThemeController.accentKey] = kLegacyPurple.toARGB32().toString();
      final c = ThemeController(store: store, launcherIcon: FakeLauncherIcon(isSupported: false));
      await c.load();
      expect(c.accent, kBrandPurple);
    });

    test('başlatıcı ikonu seçilen renge eşitlenir (art arda seçimler birleştirilir), aynı anahtar tekrar uygulanmaz', () async {
      final icon = FakeLauncherIcon();
      final c = ThemeController(store: _MemStore(), launcherIcon: icon);
      await c.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(icon.applied, ['red'], reason: 'açılışta mevcut renge eşitlenir');
      await c.setAccent(const Color(0xFF1F8A4C));
      await c.setAccent(const Color(0xFF1F5FD1));
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(icon.applied, ['red', 'blue'], reason: 'ara seçim (green) atlanır');
      await c.setLogoColor(const Color(0xFF201E1D)); // sabit renk
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(icon.applied.last, 'ink');
      await c.setAccent(const Color(0xFF5B3FD1)); // sabit logo: ikon değişmez
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(icon.applied.last, 'ink');
      c.dispose();
    });

    test('platform desteklemiyorsa ikon değiştirilmez', () async {
      final icon = FakeLauncherIcon(isSupported: false);
      final c = ThemeController(store: _MemStore(), launcherIcon: icon);
      await c.load();
      await c.setAccent(const Color(0xFF1F8A4C));
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(icon.applied, isEmpty);
    });
  });

  group('logo bileşeni', () {
    testWidgets('temayı izler, sabit renkte kalır ve "Fissio" adıyla yazılır', (tester) async {
      final ctrl = ThemeController(store: _MemStore(), launcherIcon: FakeLauncherIcon(isSupported: false));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Column(children: [FissioLogo(size: 80, controller: ctrl), const FissioWordmark()]),
          ),
        ),
      );
      Color painted() => ((tester
              .widget<CustomPaint>(
                find.descendant(of: find.byKey(const ValueKey('fissio-logo')).first, matching: find.byType(CustomPaint)),
              )
              .painter!) as FissioLogoPainter)
          .color;
      expect(painted(), kDefaultAccent);
      await ctrl.setAccent(const Color(0xFF1F5FD1));
      await tester.pump();
      expect(painted(), const Color(0xFF1F5FD1));
      await ctrl.setLogoColor(const Color(0xFFAE1800));
      await ctrl.setAccent(const Color(0xFF1F8A4C));
      await tester.pump();
      expect(painted(), const Color(0xFFAE1800), reason: 'sabit renk vurgudan bağımsız');
      expect(find.text('Fissio'), findsOneWidget, reason: 'uygulama adı Fissio');
      expect(find.byKey(const ValueKey('fissio-logo')), findsNWidgets(2));
    });

    testWidgets('logo boyanır (hatasız, gölge dahil)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: FissioLogo(size: 120, color: const Color(0xFF5B3FD1))))),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Tercihler: vurgu ve logo seçimi', () {
    testWidgets('7 vurgu rengi; logo bölümü temaya uygun / sabit renk geçişi yapar', (tester) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      themeController.logoOverride = null;
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const PreferencesPage()));
      await tester.pump();
      for (final o in kAccentOptions) {
        expect(find.text(o.name), findsOneWidget, reason: '${o.name} vurgu seçeneği');
      }
      expect(find.text('Uygulama logosu'.toUpperCase()), findsOneWidget);
      expect(find.text('Temaya uygun'), findsOneWidget);
      expect(find.byKey(const ValueKey('logo-blue')), findsNothing, reason: 'sabit renk seçilmeden palet gizli');
      await tester.tap(find.text('Sabit renk'));
      await tester.pump();
      for (final p in kBrandPalette) {
        expect(find.byKey(ValueKey('logo-${p.key}')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('logo-blue')));
      await tester.pump();
      expect(themeController.logoColor, const Color(0xFF1F5FD1));
      expect(themeController.logoFollowsTheme, isFalse);
      await tester.tap(find.text('Temaya uygun'));
      await tester.pump();
      expect(themeController.logoFollowsTheme, isTrue);
      themeController.logoOverride = null;
    });
  });

  group('widget kısayolu (fissio://scan)', () {
    test('yalnızca fissio://scan bekleyen istek olur ve bir kez tüketilir', () {
      final d = DeepLinkController();
      var notified = 0;
      d.addListener(() => notified++);
      d.handle(null);
      d.handle(Uri.parse('https://example.com/scan'));
      d.handle(Uri.parse('fissio://settings'));
      expect(d.hasPendingScan, isFalse);
      expect(d.consumeScan(), isFalse);

      d.handle(Uri.parse(kScanDeepLink));
      expect(d.hasPendingScan, isTrue);
      expect(notified, 1);
      expect(d.consumeScan(), isTrue);
      expect(d.consumeScan(), isFalse, reason: 'tek seferlik');
    });

    test('iOS widget adresi (fissio://scan?homeWidget) ve boş yol da taramayı tetikler', () {
      final d = DeepLinkController();
      d.handle(Uri.parse('fissio://scan?homeWidget'));
      expect(d.consumeScan(), isTrue);
      d.handle(Uri.parse('fissio://home?homeWidget'));
      expect(d.hasPendingScan, isFalse, reason: 'yalnızca scan hedefi kamerayı açar');
    });
  });
}
