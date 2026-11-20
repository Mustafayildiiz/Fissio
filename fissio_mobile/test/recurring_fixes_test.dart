import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/budget_widgets.dart';
import 'package:fissio_mobile/pages/receipt_form_page.dart';
import 'package:fissio_mobile/pages/recurring_page.dart';
import 'package:fissio_mobile/recurring.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

final _now = DateTime(2026, 5, 15, 12);

Expense _e(
  int id,
  String merchant,
  double amount,
  DateTime date, {
  int day = 5,
  int cat = 10,
  RecurringKind kind = RecurringKind.fixed,
}) => Expense(
  id: id,
  merchant: merchant,
  amount: amount,
  date: date,
  categoryId: cat,
  categoryName: 'x',
  note: '',
  items: const [],
  clientUid: 'u$id',
  profileUid: 'p1',
  recurringDay: day,
  recurringKind: kind,
);

ReceiptDraft _draft(String uid, String merchant, double amount, DateTime date, int day) => ReceiptDraft(
  clientUid: uid,
  merchant: merchant,
  categoryId: 1,
  date: date,
  items: [ExpenseItem('kalem', amount, categoryId: 1)],
  recurringDay: day,
);

void main() {
  group('seriesMatchFor (bulanık seri eşleşmesi)', () {
    RecurringProjection proj(List<Expense> es) => buildRecurring(es, _now);

    test('birebir anahtar her zaman eşleşir (tutar gerekmez, eski davranış)', () {
      final p = proj([_e(1, 'BEDAŞ', 500, DateTime(2026, 4, 5))]);
      expect(seriesMatchFor(p.items, 'bedaş', 10)?.merchant, 'BEDAŞ');
      expect(seriesMatchFor(p.items, 'bedaş', 11), isNull, reason: 'kategori farklı');
      expect(seriesMatchFor(p.items, '', 10), isNull);
      expect(seriesMatchFor(p.items, 'BEDAŞ', null), isNull);
    });

    test('alt küme isim + marj içi tutar + bu ay ödenmemiş → eşleşir', () {
      final p = proj([_e(1, 'BEDAŞ', 500, DateTime(2026, 4, 5))]);
      expect(seriesMatchFor(p.items, 'BEDAŞ A.Ş.', 10, amount: 520)?.merchant, 'BEDAŞ');
      expect(seriesMatchFor(p.items, 'BEDAŞ A.Ş.', 10, amount: 650)?.merchant, 'BEDAŞ', reason: '%30 sınırı dahil');
    });

    test('tutar marjı dışı, tutar yok ya da kategori farklıysa bulanık eşleşme yok', () {
      final p = proj([_e(1, 'Migros', 500, DateTime(2026, 4, 5))]);
      expect(seriesMatchFor(p.items, 'Migros Jet', 10, amount: 90), isNull, reason: 'küçük market alışverişi');
      expect(seriesMatchFor(p.items, 'Migros Jet', 10, amount: 651), isNull, reason: '%30 üstü');
      expect(seriesMatchFor(p.items, 'Migros Jet', 10), isNull, reason: 'tutar yok');
      expect(seriesMatchFor(p.items, 'Migros Jet', 11, amount: 500), isNull);
      expect(seriesMatchFor(p.items, 'Şok Market', 10, amount: 500), isNull, reason: 'ortak jeton yok');
    });

    test('bu ay zaten ödenmiş seriye bulanık bağlanmaz (ikinci alışveriş); birebir korunur', () {
      final p = proj([_e(1, 'Migros', 500, DateTime(2026, 5, 2), day: 2)]);
      expect(p.items.single.paidThisMonth, isTrue);
      expect(seriesMatchFor(p.items, 'Migros Jet', 10, amount: 500), isNull);
      expect(seriesMatchFor(p.items, 'Migros', 10, amount: 500)?.merchant, 'Migros');
    });

    test('yalnızca kısa (<3 karakter) ortak jeton yetmez', () {
      final p = proj([_e(1, 'A.Ş. Su', 100, DateTime(2026, 4, 5))]);
      expect(seriesMatchFor(p.items, 'Su', 10, amount: 100), isNull);
    });

    test('birden çok aday: en yakın tutar kazanır; eşitlikte hiçbiri', () {
      final close = proj([
        _e(1, 'Su İdaresi Bakım', 300, DateTime(2026, 4, 6)),
        _e(2, 'Su İdaresi Kira', 320, DateTime(2026, 4, 7)),
      ]);
      expect(seriesMatchFor(close.items, 'Su İdaresi', 10, amount: 318)?.merchant, 'Su İdaresi Kira');
      final tie = proj([
        _e(1, 'Su İdaresi Bakım', 300, DateTime(2026, 4, 6)),
        _e(2, 'Su İdaresi Kira', 300, DateTime(2026, 4, 7)),
      ]);
      expect(seriesMatchFor(tie.items, 'Su İdaresi', 10, amount: 300), isNull, reason: 'belirsiz: devralınmaz');
    });
  });

  group('toplama dahil olma', () {
    test('son fişi 2 aydan eski ödenmemiş seri listede kalır ama toplama girmez', () {
      final p = buildRecurring([
        _e(1, 'Netflix', 100, DateTime(2026, 5, 2), day: 2), // ödendi
        _e(2, 'Salon', 150, DateTime(2026, 3, 5)), // 2 ay → sayılır
        _e(3, 'Eski abonelik', 80, DateTime(2026, 2, 5)), // 3 ay → listede, sayılmaz
      ], _now);
      expect(p.items.length, 3);
      expect(p.items.firstWhere((i) => i.merchant == 'Eski abonelik').countsInTotal, isFalse);
      expect(p.items.firstWhere((i) => i.merchant == 'Salon').countsInTotal, isTrue);
      expect(p.monthlyTotal, 250);
      expect(p.remainingTotal, 150);
      expect(p.paidTotal, 100);
    });

    test('upcomingPaymentsOf bu ay ödenmişi yaklaşan saymaz', () {
      final p = buildRecurring([_e(1, 'Netflix', 100, DateTime(2026, 5, 2), day: 2)], _now);
      expect(p.items.single.nextDue, DateTime.utc(2026, 6, 2));
      expect(upcomingPaymentsOf(p.items, _now), isEmpty);
    });
  });

  group('Tümü sayfası', () {
    Widget host(Harness h) => MaterialApp(
      theme: buildTheme(brightness: Brightness.light),
      home: RecurringPage(app: h.app, now: _now),
    );

    testWidgets('ödenmiş "Yaklaşan"da yok; gecikme Tümü listesinde görünür; bayat seri toplama dahil değil', (tester) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Harness h;
      await tester.runAsync(() async {
        h = Harness(clock: () => _now);
        await h.signIn('ali@x.co');
        await h.app.saveDraft(_draft('s1', 'Netflix', 100, DateTime(2026, 5, 2), 2)); // ödendi
        await h.app.saveDraft(_draft('s2', 'Spor', 200, DateTime(2026, 4, 20), 20)); // 5/20 yaklaşan
        await h.app.saveDraft(_draft('s3', 'Salon', 150, DateTime(2026, 3, 5), 5)); // gecikmiş, sayılır
        await h.app.saveDraft(_draft('s4', 'Eski abonelik', 80, DateTime(2026, 2, 5), 5)); // gecikmiş, sayılmaz
      });
      await tester.pumpWidget(host(h));
      await tester.pump();

      // Yaklaşan: Spor + gecikmiş Salon + gecikmiş Eski abonelik = 3; Tümü: 4 → 7 satır.
      expect(find.byType(RecurringTile), findsNWidgets(7));
      expect(find.text('Netflix'), findsOneWidget, reason: 'ödenmiş yalnızca Tüm giderler listesinde');
      expect(find.text('Spor'), findsNWidgets(2));

      // Tümü'nde de gecikme görünür; ödeme günü yerine "N gün gecikti".
      expect(find.textContaining('gün gecikti', findRichText: true), findsWidgets);
      expect(find.textContaining('ayın 5. günü', findRichText: true), findsNothing);
      expect(find.textContaining('toplama dahil değil', findRichText: true), findsWidgets);

      // Ödenen 100 + kalan (Spor 200 + Salon 150); Eski abonelik (80) girmez.
      expect(
        tester.widget<Text>(find.byKey(const Key('fixed-projection-split'))).data,
        'Ödenen ${fmtMoney(100)} · Kalan ${fmtMoney(350)}',
      );
    });

    testWidgets('dar ekranda (320 px) uzun ad ve geniş aralık taşma üretmez', (tester) async {
      tester.view.physicalSize = const Size(320, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Harness h;
      await tester.runAsync(() async {
        h = Harness(clock: () => _now);
        await h.signIn('ali@x.co');
        for (final (m, a) in [(2, 12345.67), (3, 98765.43), (4, 54321.0)]) {
          await h.app.saveDraft(
            ReceiptDraft(
              clientUid: 'n$m',
              merchant: 'Çok uzun bir işletme adı Anonim Şirketi Elektrik Dağıtım Hizmetleri',
              categoryId: 1,
              date: DateTime(2026, m, 20),
              items: [ExpenseItem('kalem', a, categoryId: 1)],
              recurringDay: 20,
              recurringKind: RecurringKind.variable,
            ),
          );
        }
      });
      await tester.pumpWidget(host(h));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(RecurringTile), findsWidgets);
    });
  });

  group('bulanık eşleşme: kayıt seriyi sürdürür (çift seri / çift sayım yok)', () {
    testWidgets('"BEDAŞ A.Ş." taraması mevcut "BEDAŞ" serisini devralır ve tek seri kalır', (tester) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Harness h;
      await tester.runAsync(() async {
        h = Harness(clock: () => _now);
        await h.signIn('ali@x.co');
        await h.app.saveDraft(_draft('bedas-nisan', 'BEDAŞ', 500, DateTime(2026, 4, 5), 5));
      });
      expect(h.app.recurring.items.single.paidThisMonth, isFalse);

      // Tarama: OCR işletme adını farklı okudu ("BEDAŞ A.Ş."), tutar eskiye yakın, tekrar işareti yok.
      final draft = ReceiptDraft(
        merchant: 'BEDAŞ A.Ş.',
        categoryId: 1,
        date: DateTime(2026, 5, 5),
        items: [ExpenseItem('fatura', 520, categoryId: 1)],
      );
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ReceiptFormPage(initialDraft: draft, app: h.app)));
      await tester.pump();
      expect(draft.recurringDay, 5, reason: 'seri devralındı');
      expect(find.byKey(const Key('recurring-inherited')), findsOneWidget);
      expect(find.textContaining('İşletme adı "BEDAŞ" olarak kaydedilir'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('Fişi oluştur'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      final items = h.app.recurring.items;
      expect(items.length, 1, reason: 'ikinci bir seri açılmamalı');
      expect(items.single.merchant, 'BEDAŞ');
      expect(items.single.paidThisMonth, isTrue);
      expect(h.app.recurring.monthlyTotal, 520, reason: 'eski 500 + yeni 520 çiftlenmemeli');
    });
  });
}
