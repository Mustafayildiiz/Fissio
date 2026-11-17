import 'package:fissio_mobile/pages/auth_page.dart';
import 'package:fissio_mobile/pages/home_page.dart';
import 'package:fissio_mobile/pages/preferences_page.dart';
import 'package:fissio_mobile/pages/profile_select_page.dart';
import 'package:fissio_mobile/pages/receipt_detail_page.dart';
import 'package:fissio_mobile/pages/receipt_form_page.dart';
import 'package:fissio_mobile/pages/receipts_page.dart';
import 'package:fissio_mobile/pages/scan_page.dart';
import 'package:fissio_mobile/pages/settings_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget w, {Brightness brightness = Brightness.light}) => MaterialApp(
      theme: buildTheme(brightness: brightness),
      home: Scaffold(body: w),
    );

void main() {
  test('para biçimi', () {
    expect(fmtMoney(1250.5), '1.250,50 ₺');
    expect(fmtMoney(0), '0,00 ₺');
    expect(fmtMoney(1234567.89), '1.234.567,89 ₺');
  });

  test('tarih biçimi', () {
    expect(fmtDate(DateTime(2026, 5, 3)), '03.05.2026');
    expect(isoDate(DateTime(2026, 5, 3)), '2026-05-03');
  });

  for (final brightness in Brightness.values) {
    testWidgets('tüm ana ekranlar hatasız çizilir (${brightness.name})', (tester) async {
      final filter = ValueNotifier<int?>(null);
      Future<void> show(Widget w) async {
        await tester.pumpWidget(_wrap(w, brightness: brightness));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }

      await show(const ProfileSelectPage());
      await show(const AuthPage());
      await show(HomePage(onOpenCategory: (_) {}));
      await show(ReceiptsPage(categoryFilter: filter));
      await show(const SettingsPage());
      await show(const PreferencesPage());
      await show(const ReceiptFormPage());
      await show(const ScanPage());
      await show(const ReceiptDetailPage(id: 999));
    });
  }
}
