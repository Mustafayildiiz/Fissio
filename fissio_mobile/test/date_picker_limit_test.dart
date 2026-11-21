import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/receipt_form_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pickableToday / clampPickerDate', () {
    test('yerel günün başlangıcı: saat kısmı atılır, yarın dahil değil', () {
      final last = pickableToday(DateTime(2026, 11, 21, 23, 59, 30));
      expect(last, DateTime(2026, 11, 21));
      expect(DateTime(2026, 11, 22).isAfter(last), isTrue);
    });

    test('ileri tarihli taslak (OCR now+2 gün) bugüne çekilir, geçmiş olduğu gibi kalır', () {
      final last = DateTime(2026, 11, 21);
      expect(clampPickerDate(DateTime(2026, 11, 23, 10), last), last);
      expect(clampPickerDate(DateTime(2026, 11, 20, 18, 30), last), DateTime(2026, 11, 20));
    });
  });

  group('fiş formu tarih seçici', () {
    Future<void> openPicker(WidgetTester tester, DateTime draftDate) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final draft = ReceiptDraft(date: draftDate);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ReceiptFormPage(initialDraft: draft)));
      await tester.pump();
      await tester.tap(find.text('Tarih'));
      await tester.pumpAndSettle();
    }

    testWidgets('yarın seçilemez, bugün seçilebilir', (tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await openPicker(tester, today);
      final picker = tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
      expect(picker.lastDate, today);
      expect(picker.initialDate, today);
    });

    testWidgets('ileri tarihli taslakla picker assert atmadan açılır', (tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await openPicker(tester, today.add(const Duration(days: 2)));
      expect(tester.takeException(), isNull);
      final picker = tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
      expect(picker.initialDate, today);
    });
  });
}
