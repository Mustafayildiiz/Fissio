import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/budget_widgets.dart';
import 'package:fissio_mobile/pages/receipt_form_page.dart';
import 'package:fissio_mobile/recurring.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Sabit / değişken tutarlı tekrarlayan giderler. "Ortak vektörler" grubu, Go tarafındaki
/// services/expense/recurring_test.go ile BİREBİR aynı veri ve beklentileri içerir; ikisi birlikte değişmeli.

Expense _e(
  int id,
  String merchant,
  double amount,
  DateTime date, {
  int day = 0,
  RecurringKind kind = RecurringKind.fixed,
  double estimate = 0,
  int cat = 7,
}) => Expense(
  id: id,
  merchant: merchant,
  amount: amount,
  date: date,
  categoryId: cat,
  categoryName: 'Fatura / Abonelik',
  note: '',
  items: const [],
  clientUid: 'u$id',
  profileUid: 'p1',
  recurringDay: day,
  recurringKind: kind,
  recurringEstimate: estimate,
);

RecurringItem _of(RecurringProjection p, String merchant) => p.items.firstWhere((i) => i.merchant == merchant);

List<Expense> _electricity() => [
  _e(1, 'CK Elektrik', 400, DateTime(2026, 2, 20), day: 20, kind: RecurringKind.variable),
  _e(2, 'CK Elektrik', 500, DateTime(2026, 3, 20), day: 20, kind: RecurringKind.variable),
  _e(3, 'CK Elektrik', 600, DateTime(2026, 4, 20), day: 20, kind: RecurringKind.variable),
];

void main() {
  final today = DateTime(2026, 5, 15);

  group('ortak vektörler (Go ile aynı)', () {
    test('değişken fatura: son 3 ayın hareketli ortalaması ve min-maks aralığı', () {
      final p = buildRecurring(_electricity(), today);
      final el = _of(p, 'CK Elektrik');
      expect(el.kind, RecurringKind.variable);
      expect([el.expected, el.minAmount, el.maxAmount, el.historyCount], [500, 400, 600, 3]);
      expect(el.paidThisMonth, isFalse);
      expect(el.monthAmount, 500);
      expect(el.nextDue, DateTime.utc(2026, 5, 20));
      expect([p.monthlyTotal, p.remainingTotal, p.paidTotal, p.minTotal, p.maxTotal], [500, 500, 0, 400, 600]);
    });

    test('yeni ayın faturası girilince otomatik ödendi: gerçek tutar projeksiyona girer', () {
      final p = buildRecurring([
        ..._electricity(),
        _e(4, 'CK Elektrik', 520, DateTime(2026, 5, 18), day: 20, kind: RecurringKind.variable),
      ], today);
      final el = _of(p, 'CK Elektrik');
      expect([el.paidThisMonth, el.actualAmount, el.monthAmount], [true, 520, 520]);
      // Sonraki ay için beklenen: Nisan 600, Mart 500, Mayıs 520 → 540; aralık 500-600.
      expect([el.expected, el.minAmount, el.maxAmount], [540, 500, 600]);
      expect(el.nextDue, DateTime.utc(2026, 6, 20));
      expect([p.monthlyTotal, p.paidTotal, p.remainingTotal, p.minTotal, p.maxTotal], [520, 520, 0, 520, 520]);
    });

    test('sabit gider ortalamaya katılmaz; karışık projeksiyon (ödenen gerçek + kalan tahmin)', () {
      final p = buildRecurring([
        ..._electricity(),
        _e(10, 'Ev sahibi', 4500, DateTime(2026, 3, 1), day: 1),
        _e(11, 'Ev sahibi', 5000, DateTime(2026, 4, 1), day: 1),
        _e(12, 'Ev sahibi', 5000, DateTime(2026, 5, 1), day: 1),
      ], today);
      final kira = _of(p, 'Ev sahibi');
      expect([kira.kind, kira.expected, kira.minAmount, kira.maxAmount], [RecurringKind.fixed, 5000, 5000, 5000]);
      expect([kira.paidThisMonth, kira.monthAmount], [true, 5000]);
      expect(p.items.length, 2);
      expect([p.monthlyTotal, p.paidTotal, p.remainingTotal, p.minTotal, p.maxTotal], [5500, 5000, 500, 5400, 5600]);
    });

    test('geçmiş yetersizse tahmin, o da yoksa son tutar; pencere en çok 3 ay; ayda tek fiş', () {
      var p = buildRecurring([_e(1, 'Su', 250, DateTime(2026, 4, 10), day: 10, kind: RecurringKind.variable, estimate: 300)], today);
      var su = _of(p, 'Su');
      expect([su.expected, su.minAmount, su.maxAmount, su.historyCount, su.estimate], [300, 300, 300, 1, 300]);

      p = buildRecurring([_e(1, 'Su', 250, DateTime(2026, 4, 10), day: 10, kind: RecurringKind.variable)], today);
      expect(_of(p, 'Su').expected, 250);

      p = buildRecurring([
        _e(1, 'Su', 200, DateTime(2026, 3, 10), day: 10, kind: RecurringKind.variable),
        _e(2, 'Su', 300, DateTime(2026, 4, 10), day: 10, kind: RecurringKind.variable, estimate: 999),
      ], today);
      su = _of(p, 'Su');
      expect([su.expected, su.minAmount, su.maxAmount, su.historyCount], [250, 200, 300, 2], reason: '2 ay varsa tahmin değil ortalama');

      p = buildRecurring([
        _e(9, 'CK Elektrik', 5000, DateTime(2026, 1, 20), day: 20, kind: RecurringKind.variable),
        ..._electricity(),
      ], today);
      expect([_of(p, 'CK Elektrik').expected, _of(p, 'CK Elektrik').historyCount], [500, 3], reason: 'Ocak pencereye girmez');

      p = buildRecurring([
        _e(1, 'Gaz', 100, DateTime(2026, 3, 10), day: 10, kind: RecurringKind.variable),
        _e(2, 'Gaz', 100, DateTime(2026, 4, 10), day: 10, kind: RecurringKind.variable),
        _e(3, 'Gaz', 700, DateTime(2026, 4, 25), day: 10, kind: RecurringKind.variable),
      ], today);
      expect([_of(p, 'Gaz').expected, _of(p, 'Gaz').historyCount], [400, 2], reason: 'ayın en son fişi sayılır');
    });
  });

  test('hatırlatıcı değişken faturada "yaklaşık" tutarı söyler', () {
    final items = buildRecurring(_electricity(), today).items;
    final plans = planReminders(items, DateTime(2026, 5, 10, 8));
    expect(plans.every((p) => p.body.toLowerCase().contains('yaklaşık')), isTrue);
    expect(plans.first.body, contains(fmtMoney(500)));
  });

  test('Expense / ReceiptDraft / yerel JSON tekrar türünü ve tahmini taşır', () {
    final e = _e(1, 'Su', 250, DateTime(2026, 4, 10), day: 10, kind: RecurringKind.variable, estimate: 300);
    final back = Expense.fromLocalJson(e.toLocalJson());
    expect([back.recurringKind, back.recurringEstimate], [RecurringKind.variable, 300]);
    final d = ReceiptDraft.from(e);
    expect([d.recurringKind, d.recurringEstimate], [RecurringKind.variable, 300]);
    expect(d.toRequestBody()['recurring_kind'], 'variable');
    expect(d.toRequestBody()['recurring_estimate'], 300);
    // Sabit giderde tahmin gönderilmez (0 = yok).
    d.recurringKind = RecurringKind.fixed;
    expect(d.toRequestBody()['recurring_estimate'], 0);
  });

  group('arayüz', () {
    late Harness h;
    setUp(() => h = Harness(clock: () => DateTime(2026, 5, 15, 12)));

    testWidgets('değişken fatura satırı ≈ tahmini tutar + aralık; yeni ay faturası "Ödendi" ve gerçek tutarı gösterir', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await h.signIn('ali@x.co');
        for (final e in _electricity()) {
          await h.app.saveDraft(
            ReceiptDraft(
              merchant: e.merchant,
              categoryId: 1,
              date: e.date,
              items: [ExpenseItem('fatura', e.amount, categoryId: 1)],
              recurringDay: 20,
              recurringKind: RecurringKind.variable,
            ),
          );
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: SingleChildScrollView(child: FixedExpensesSection(app: h.app, now: DateTime(2026, 5, 15))),
          ),
        ),
      );
      await tester.pump();
      final id = h.app.recurring.items.single.lastExpenseId;
      expect(tester.widget<Text>(find.byKey(const Key('fixed-projection-total'))).data, fmtMoney(500));
      expect(tester.widget<Text>(find.byKey(Key('recurring-amount-$id'))).data, '≈ ${fmtMoney(500)}');
      expect(find.byKey(const Key('range-caption')), findsOneWidget);
      expect(find.text('${fmtMoney(400)} – ${fmtMoney(600)}'), findsOneWidget);
      expect(find.byKey(const Key('paid-badge')), findsNothing);
      expect(find.byKey(const Key('fixed-projection-range')), findsOneWidget);

      // Mayıs faturası girildi → aynı ekran (yeniden kurmadan) "Ödendi" + gerçek tutar.
      await tester.runAsync(
        () => h.app.saveDraft(
          ReceiptDraft(
            merchant: 'CK Elektrik',
            categoryId: 1,
            date: DateTime(2026, 5, 14),
            items: [ExpenseItem('fatura', 520, categoryId: 1)],
            recurringDay: 20,
            recurringKind: RecurringKind.variable,
          ),
        ),
      );
      await tester.pump();
      final id2 = h.app.recurring.items.single.lastExpenseId;
      expect(tester.widget<Text>(find.byKey(const Key('fixed-projection-total'))).data, fmtMoney(520));
      expect(tester.widget<Text>(find.byKey(Key('recurring-amount-$id2'))).data, fmtMoney(520));
      expect(find.byKey(const Key('paid-badge')), findsOneWidget);
      expect(find.byKey(const Key('range-caption')), findsNothing);
      expect(find.byKey(const Key('fixed-projection-range')), findsNothing);
    });

    testWidgets('fiş formu: tür seçimi ve tahmini tutar; kayıtta taslağa yazılır', (tester) async {
      tester.view.physicalSize = const Size(900, 2800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() => h.signIn('ali@x.co'));
      final draft = ReceiptDraft(date: DateTime(2026, 5, 17));
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ReceiptFormPage(initialDraft: draft, app: h.app)));
      await tester.pump();
      expect(find.byKey(const Key('recurring-kind')), findsNothing);

      await tester.tap(find.byKey(const Key('recurring-switch')));
      await tester.pump();
      expect(find.byKey(const Key('recurring-kind')), findsOneWidget);
      expect(find.byKey(const Key('recurring-estimate')), findsNothing, reason: 'sabit: tahmin alanı yok');

      await tester.tap(find.text('Değişken (fatura)'));
      await tester.pump();
      expect(draft.recurringKind, RecurringKind.variable);
      expect(find.byKey(const Key('recurring-estimate')), findsOneWidget);
      await tester.enterText(find.descendant(of: find.byKey(const Key('recurring-estimate')), matching: find.byType(TextField)), '850');
      await tester.tap(find.text('Sabit tutar'));
      await tester.pump();
      expect(draft.recurringKind, RecurringKind.fixed);
      expect(find.byKey(const Key('recurring-estimate')), findsNothing);
    });

    testWidgets('yeni ay faturası aynı kurumun serisini devralır: günü, türü ve tahmini önerilir', (tester) async {
      tester.view.physicalSize = const Size(900, 2800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await h.signIn('ali@x.co');
        for (final e in _electricity()) {
          await h.app.saveDraft(
            ReceiptDraft(
              merchant: e.merchant,
              categoryId: 1,
              date: e.date,
              items: [ExpenseItem('fatura', e.amount, categoryId: 1)],
              recurringDay: 20,
              recurringKind: RecurringKind.variable,
              recurringEstimate: 450,
            ),
          );
        }
      });
      // Tarama sonucu: aynı kurum + kategori, tekrar işareti YOK.
      final draft = ReceiptDraft(
        merchant: 'ck elektrik',
        categoryId: 1,
        date: DateTime(2026, 5, 14),
        items: [ExpenseItem('fatura', 520, categoryId: 1)],
      );
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ReceiptFormPage(initialDraft: draft, app: h.app)));
      await tester.pump();
      expect(draft.recurringDay, 20);
      expect(draft.recurringKind, RecurringKind.variable);
      expect(find.byKey(const Key('recurring-inherited')), findsOneWidget);
      expect(tester.widget<Switch>(find.byKey(const Key('recurring-switch'))).value, isTrue);

      // Kullanıcı kapatırsa (seriyi bitirmek istiyor) devralma bir daha karışmaz.
      await tester.tap(find.byKey(const Key('recurring-switch')));
      await tester.pump();
      expect(draft.recurringDay, 0);
      expect(find.byKey(const Key('recurring-inherited')), findsNothing);
    });
  });
}
