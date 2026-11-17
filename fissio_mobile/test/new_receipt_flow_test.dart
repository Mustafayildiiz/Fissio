import 'package:fissio_mobile/app_state.dart';
import 'package:fissio_mobile/ocr/ocr_engine.dart';
import 'package:fissio_mobile/pages/preferences_page.dart';
import 'package:fissio_mobile/pages/receipt_form_page.dart';
import 'package:fissio_mobile/pages/scan_page.dart';
import 'package:fissio_mobile/pages/shell_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'support/fake_backend.dart';

Widget _wrap(Widget w) => MaterialApp(theme: buildTheme(brightness: Brightness.light), home: w);

void main() {
  testWidgets('Yeni fiş "+" doğrudan tarama sayfasını açar', (tester) async {
    await tester.pumpWidget(_wrap(const ShellPage()));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Yeni fiş'));
    await tester.pumpAndSettle();
    expect(find.byType(ScanPage), findsOneWidget);
    expect(find.byType(ReceiptFormPage), findsNothing);
  });

  testWidgets('tarama ekranında OCR seçici yok; Manuel formu açar', (tester) async {
    await tester.pumpWidget(_wrap(const ScanPage()));
    await tester.pump();
    expect(find.byTooltip('OCR motoru'), findsNothing);
    expect(find.byIcon(LucideIcons.slidersHorizontal), findsNothing);
    await tester.tap(find.text('Manuel'));
    await tester.pumpAndSettle();
    expect(find.byType(ReceiptFormPage), findsOneWidget);
  });

  testWidgets('Tercihler: tüm modlar ve motorlar listelenir, seçim kalıcıdır', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = MemPrefs();
    final saved = themeController;
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Global denetleyiciyi değiştirmeden aynı akışı yeni örnekle de doğrula.
    await tester.pumpWidget(_wrap(const PreferencesPage()));
    await tester.pump();

    for (final t in ['Otomatik', 'Sunucu', 'Cihaz']) {
      expect(find.text(t), findsWidgets);
    }
    for (final e in appState.ocrFactory.availableEngines) {
      expect(find.text(ocrEngineLabel(e)), findsOneWidget);
    }

    await tester.tap(find.text('Cihaz'));
    await tester.pump();
    expect(saved.ocrMode, OcrMode.onDevice);
    await tester.tap(find.text(ocrEngineLabel('custom')));
    await tester.pump();
    expect(saved.ocrEngine, 'custom');

    // Kalıcılık: aynı depodan yeni denetleyici okur.
    final c = ThemeController(store: prefs);
    await c.setOcrMode(OcrMode.server);
    await c.setOcrEngine('custom');
    final reloaded = ThemeController(store: prefs);
    await reloaded.load();
    expect(reloaded.ocrMode, OcrMode.server);
    expect(reloaded.ocrEngine, 'custom');
    expect(prefs.data[ThemeController.ocrEngineKey], 'custom');
    await saved.setOcrMode(OcrMode.auto);
    await saved.setOcrEngine('paddleocr');
  });
}
