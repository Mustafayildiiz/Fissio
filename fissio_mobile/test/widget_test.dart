import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/auth_page.dart';
import 'package:fissio_mobile/pages/home_page.dart';
import 'package:fissio_mobile/pages/items_page.dart';
import 'package:fissio_mobile/pages/receipt_detail_page.dart';
import 'package:fissio_mobile/pages/receipt_form_page.dart';
import 'package:fissio_mobile/pages/receipts_page.dart';
import 'package:fissio_mobile/pages/scan_page.dart';
import 'package:fissio_mobile/pages/settings_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget w) => MaterialApp(theme: buildTheme(), home: Scaffold(body: w));

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

  testWidgets('tüm ana ekranlar hatasız çizilir', (tester) async {
    final filter = ValueNotifier<int?>(null);
    await tester.pumpWidget(_wrap(const AuthPage()));
    await tester.pump();
    await tester.pumpWidget(_wrap(HomePage(onOpenCategory: (_) {})));
    await tester.pump();
    await tester.pumpWidget(_wrap(ReceiptsPage(categoryFilter: filter)));
    await tester.pump();
    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.pump();
    await tester.pumpWidget(_wrap(const ReceiptFormPage()));
    await tester.pump();
    await tester.pumpWidget(_wrap(ItemsPage(draft: ReceiptDraft(categoryId: 1))));
    await tester.pump();
    await tester.pumpWidget(_wrap(const ScanPage()));
    await tester.pump();
    await tester.pumpWidget(_wrap(const ReceiptDetailPage(id: 999)));
    await tester.pump();
  });
}
