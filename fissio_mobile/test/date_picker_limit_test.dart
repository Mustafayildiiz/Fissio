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

    test('alt sınır: içe aktarmanın kabul ettiği en eski yıl (1990) seçilebilir, altı kısılır', () {
      final last = DateTime(2026, 11, 21);
      expect(kPickerFirstDate, DateTime(1990));
      expect(clampPickerDate(DateTime(1995, 3, 4), last), DateTime(1995, 3, 4));
      expect(clampPickerDate(DateTime(1985, 1, 1), last), kPickerFirstDate);
      expect(clampPickerDate(DateTime(1999, 1, 1), last, first: DateTime(2000)), DateTime(2000));
    });

    test('aralık: saat geri gidip son tarih bugünü aşarsa kısılır; tamamen dışarıdaysa null', () {
      final last = DateTime(2026, 11, 21);
      final r = clampPickerRange(DateTimeRange(start: DateTime(2026, 11, 10), end: DateTime(2026, 11, 22)), last)!;
      expect(r.start, DateTime(2026, 11, 10));
      expect(r.end, last);
      expect(clampPickerRange(null, last), isNull);
      // Başlangıç da bugünden sonraysa ikisi de bugüne kısılır (tek günlük geçerli aralık).
      final f = clampPickerRange(DateTimeRange(start: DateTime(2026, 11, 23), end: DateTime(2026, 11, 25)), last)!;
      expect(f.start, last);
      expect(f.end, last);
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

    testWidgets('1990\'lardan içe aktarılmış fişte picker assert atmadan açılır (eski alt sınır 2000\'di)', (tester) async {
      await openPicker(tester, DateTime(1995, 6, 15));
      expect(tester.takeException(), isNull);
      final picker = tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
      expect(picker.initialDate, DateTime(1995, 6, 15));
      expect(picker.firstDate, kPickerFirstDate);
    });
  });
}
