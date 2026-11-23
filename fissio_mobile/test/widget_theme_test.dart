import 'package:fissio_mobile/pages/preferences_page.dart';
import 'package:fissio_mobile/services/widget_sync.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

void main() {
  late WidgetTheme prevTheme;
  late Color? prevLogo;
  late bool prevShow;
  setUp(() {
    prevTheme = themeController.widgetTheme;
    prevLogo = themeController.logoOverride;
    prevShow = themeController.showOcrEngine;
    themeController.widgetTheme = WidgetTheme.system;
    themeController.logoOverride = null;
  });
  tearDown(() {
    themeController.widgetTheme = prevTheme;
    themeController.logoOverride = prevLogo;
    themeController.showOcrEngine = prevShow;
  });

  test('marka rengi yerel tarafın okuduğu #AARRGGBB metnine çevrilir', () {
    expect(widgetAccentHex(0xFFEC3013), '#FFEC3013');
    expect(widgetAccentHex(0xFF1F5FD1), '#FF1F5FD1');
    expect(widgetAccentHex(0x00000001), '#00000001');
  });

  test('4 widget sağlayıcısı: Android sınıfı + iOS kind', () {
    expect(WidgetKeys.providers.length, 4);
    expect(WidgetKeys.providers.map((p) => p.ios), ['FissioWidget', 'FissioScanWidget', 'FissioDigitalWidget', 'FissioCombinedWidget']);
    expect(WidgetKeys.androidQualified('FissioScanWidgetProvider'), 'com.example.fissio_mobile.FissioScanWidgetProvider');
  });

  group('tema değişince native widget\'lar anında yeniden çizilir (updateTheme)', () {
    test('açılışta mevcut tema yazılır; Tercihler\'den değişince yeni tema + marka rengi gider', () async {
      final h = Harness();
      await h.settle();
      expect(h.widget.themes, isNotEmpty, reason: 'açılışta tema widget\'lara yazılır (oturum açmadan da)');
      expect(h.widget.themes.last.$1, 'system');

      await themeController.setWidgetTheme(WidgetTheme.dark);
      await h.settle();
      expect(h.widget.themes.last.$1, 'dark');

      // Aynı tema tekrar seçilirse gereksiz yeniden çizim yok.
      final n = h.widget.themes.length;
      await themeController.setWidgetTheme(WidgetTheme.dark);
      await h.settle();
      expect(h.widget.themes.length, n);

      // Marka teması: logo/vurgu rengi de gider ve renk değişince yeniden yazılır.
      await themeController.setWidgetTheme(WidgetTheme.brand);
      await h.settle();
      expect(h.widget.themes.last.$1, 'brand');
      final accent1 = h.widget.themes.last.$2;
      expect(accent1, themeController.logoColor.toARGB32());
      await themeController.setLogoColor(const Color(0xFF1F5FD1));
      await h.settle();
      expect(h.widget.themes.last, ('brand', 0xFF1F5FD1));

      // Marka dışı temada renk değişimi widget'ı etkilemez.
      await themeController.setWidgetTheme(WidgetTheme.light);
      await h.settle();
      final m = h.widget.themes.length;
      await themeController.setLogoColor(const Color(0xFF1F8A4C));
      await h.settle();
      expect(h.widget.themes.length, m, reason: 'light temada marka rengi önemsiz');
      h.app.dispose();
    });

    test('AppState atılınca dinleyici kalkar (sızıntı yok)', () async {
      final h = Harness();
      await h.settle();
      h.app.dispose();
      final n = h.widget.themes.length;
      await themeController.setWidgetTheme(WidgetTheme.brand);
      await h.settle();
      expect(h.widget.themes.length, n);
    });
  });

  group('Tercihler sayfası', () {
    testWidgets('Widget renk teması seçici 4 seçenek sunar ve seçimi uygular', (tester) async {
      tester.view.physicalSize = const Size(800, 3400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const PreferencesPage()));
      await tester.pump();

      expect(find.text('WIDGET RENK TEMASI'), findsOneWidget);
      final seg = find.byKey(const ValueKey('widget-theme'));
      expect(seg, findsOneWidget);
      for (final label in ['Sistem', 'Açık', 'Koyu', 'Marka']) {
        expect(find.descendant(of: seg, matching: find.text(label)), findsOneWidget, reason: label);
      }
      await tester.tap(find.descendant(of: seg, matching: find.text('Marka')));
      await tester.pump();
      expect(themeController.widgetTheme, WidgetTheme.brand);
      expect(find.textContaining('logo rengini arka plan'), findsOneWidget);
    });

    testWidgets('"Fiş detayında OCR motorunu göster" anahtarı var, varsayılan açık ve ayarı değiştirir', (tester) async {
      tester.view.physicalSize = const Size(800, 3400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      themeController.showOcrEngine = true;
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const PreferencesPage()));
      await tester.pump();

      expect(find.text('Fiş detayında OCR motorunu göster'), findsOneWidget);
      final sw = find.byKey(const Key('show-ocr-engine-switch'));
      expect(tester.widget<Switch>(sw).value, isTrue);
      await tester.tap(sw);
      await tester.pump();
      expect(themeController.showOcrEngine, isFalse);
      expect(tester.widget<Switch>(sw).value, isFalse);
    });
  });
}
