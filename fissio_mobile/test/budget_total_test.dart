import 'package:fissio_mobile/budgets.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/budget_widgets.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Profilin TOPLAM aylık bütçesi: tüm kategorilerin o ayki toplamına karşı; %80 sarı / %100 kırmızı + bildirim.

ReceiptDraft _draft(String merchant, double amount, {int cat = 1, DateTime? date}) => ReceiptDraft(
  merchant: merchant,
  categoryId: cat,
  date: date ?? DateTime(2026, 5, 12),
  items: [ExpenseItem('kalem', amount, categoryId: cat)],
);

Expense _e(int id, double amount, {int cat = 1, String profile = 'p1', DateTime? date}) => Expense(
  id: id,
  merchant: 'M$id',
  amount: amount,
  date: date ?? DateTime(2026, 5, 12),
  categoryId: cat,
  categoryName: 'K$cat',
  note: '',
  items: const [],
  clientUid: 'u$id',
  profileUid: profile,
);

Budget _b(int cat, double limit, {String profile = 'p1'}) =>
    Budget(profileUid: profile, categoryId: cat, categoryName: cat == 0 ? kTotalBudgetName : 'K$cat', limit: limit);

void main() {
  final now = DateTime(2026, 5, 15, 12);

  group('hesap', () {
    test('toplam bütçe tüm kategorileri, yalnızca bu ayı ve bu profili sayar; listede ilk sıradadır', () {
      final p = computeBudgetProgress(
        [
          _e(1, 800),
          _e(2, 1200, cat: 2),
          _e(3, 9999, date: DateTime(2026, 4, 30)), // başka ay
          _e(4, 7777, profile: 'p2'), // başka profil
        ],
        [_b(1, 8000), _b(0, 20000), _b(2, 3000)],
        'p1',
        now,
      );
      expect(p.map((x) => x.budget.categoryId), [0, 1, 2], reason: 'toplam önce, sonra kategori adına göre');
      expect(p[0].spent, 2000);
      expect(p[0].budget.isTotal, isTrue);
      expect(p[1].spent, 800);
      expect(p[2].spent, 1200);
    });

    test('eşikler toplam limitte de geçerli (kuruş hassasiyeti)', () {
      BudgetLevel levelFor(double spent) =>
          computeBudgetProgress([_e(1, spent)], [_b(0, 20000)], 'p1', now).single.level;
      expect(levelFor(15999.99), BudgetLevel.ok);
      expect(levelFor(16000), BudgetLevel.warning, reason: '%80');
      expect(levelFor(19999.99), BudgetLevel.warning);
      expect(levelFor(20000), BudgetLevel.exceeded, reason: '%100');
    });

    test('toplam bütçe bildirimi: ay başına eşik başına bir kez; tek fiş iki eşiği geçerse yalnızca %100', () {
      var p = computeBudgetProgress([_e(1, 16000)], [_b(0, 20000)], 'p1', now);
      var r = evaluateBudgetAlerts(p, {}, now);
      expect(r.alerts.single.threshold, 80);
      expect(r.alerts.single.title, 'Aylık toplam bütçenin %80\'ine ulaştın');
      // Aynı eşik tekrar bildirmez.
      expect(evaluateBudgetAlerts(p, r.sent, now).alerts, isEmpty);
      p = computeBudgetProgress([_e(1, 21000)], [_b(0, 20000)], 'p1', now);
      final both = evaluateBudgetAlerts(p, {}, now);
      expect(both.alerts.single.threshold, 100);
      expect(both.alerts.single.title, 'Aylık toplam bütçe aşıldı');
      expect(both.sent.length, 2, reason: '80 de gönderildi sayılır');
    });
  });

  group('uygulama durumu', () {
    late Harness h;
    setUp(() => h = Harness(clock: () => now));

    test('toplam limit sunucuya category_id olmadan gider; kategori limitiyle yan yana yaşar', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(1, 8000);
      await h.app.setBudget(kTotalBudgetCategoryId, 20000);
      final server = h.backend.user('ali@x.co').budgets;
      expect(server.length, 2);
      expect(server.where((b) => b['category_id'] == null).single['monthly_limit'], 20000);
      expect(h.app.budgetProgress.map((p) => p.budget.categoryId), [0, 1]);
      expect(h.app.budgetProgress.first.budget.categoryName, kTotalBudgetName);

      // Güncelleme yerinde; yenilemeden sonra da toplam limit toplam olarak çözülür (kategori 0).
      await h.app.setBudget(kTotalBudgetCategoryId, 25000);
      await h.app.refresh();
      expect(h.backend.user('ali@x.co').budgets.length, 2);
      final total = h.app.budgetProgress.first;
      expect([total.budget.isTotal, total.budget.limit], [true, 25000]);
      await h.app.removeBudget(kTotalBudgetCategoryId);
      expect(h.app.budgetProgress.map((p) => p.budget.categoryId), [1]);
      expect(h.backend.user('ali@x.co').budgets.length, 1);
    });

    test('fiş kaydı toplam %80 eşiğini geçince tek bildirim gider, aynı ay tekrar gitmez', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(kTotalBudgetCategoryId, 1000);
      await h.app.saveDraft(_draft('Migros', 500));
      expect(h.notifier.shown, isEmpty);
      await h.app.saveDraft(_draft('Lokanta', 320, cat: 2)); // 820 / 1000 = %82 (iki ayrı kategori)
      expect(h.notifier.shown.map((n) => n.title), ['Aylık toplam bütçenin %80\'ine ulaştın']);
      await h.app.saveDraft(_draft('Market', 10));
      expect(h.notifier.shown.length, 1, reason: 'aynı ay + aynı eşik');
      await h.app.saveDraft(_draft('Elektronik', 200));
      expect(h.notifier.shown.map((n) => n.title).last, 'Aylık toplam bütçe aşıldı');
      expect(h.notifier.shown.length, 2);
    });

    test('çevrimdışıyken toplam limit cihaza yazılır ve bağlantı gelince buluta gider', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      await h.app.setBudget(kTotalBudgetCategoryId, 5000);
      expect(h.app.budgetProgress.single.budget.state, SyncState.pending);
      expect(h.app.pendingCount, 1);
      h.backend.offline = false;
      await h.app.flushNow(force: true);
      final server = h.backend.user('ali@x.co').budgets;
      expect(server.single['category_id'], isNull);
      expect(h.app.budgetProgress.single.budget.state, SyncState.synced);
    });

    test('senkron kapalıyken toplam limit yalnızca cihazdadır', () async {
      await h.signIn('ali@x.co');
      await h.app.setSyncEnabled(false);
      await h.app.setBudget(kTotalBudgetCategoryId, 5000);
      expect(h.backend.user('ali@x.co').budgets, isEmpty);
      expect(h.app.budgetProgress.single.budget.state, SyncState.localOnly);
    });
  });

  group('Özet bölümü', () {
    testWidgets('toplam bütçe satırı önde; eşiğe göre sarı / kırmızı; bütçe eklenince anında görünür', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = Harness(clock: () => now);
      await tester.runAsync(() async {
        await h.signIn('ali@x.co');
        await h.app.saveDraft(_draft('Migros', 800));
        await h.app.saveDraft(_draft('Lokanta', 1200, cat: 2));
      });
      // `const` üst widget: yenileme yalnızca bölümün kendi dinleyicisinden gelmeli.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: SingleChildScrollView(child: BudgetsSection(app: h.app))),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('budget-fill')), findsNothing);

      await tester.runAsync(() => h.app.setBudget(kTotalBudgetCategoryId, 2500)); // 2000 / 2500 = %80
      await tester.pump();
      final c = FissioColors.light();
      expect(find.text('Toplam aylık bütçe'), findsOneWidget);
      expect(tester.widgetList<ColoredBox>(find.byKey(const ValueKey('budget-fill'))).single.color, c.warn);
      expect(find.text('Limitin %80\'ine ulaştın'), findsOneWidget);

      await tester.runAsync(() => h.app.setBudget(1, 1000)); // kategori: 800 / 1000 = %80
      await tester.pump();
      final fills = tester.widgetList<ColoredBox>(find.byKey(const ValueKey('budget-fill'))).map((e) => e.color).toList();
      expect(fills, [c.warn, c.warn], reason: 'toplam önce, sonra kategori limiti');

      await tester.runAsync(() => h.app.setBudget(kTotalBudgetCategoryId, 1500)); // 2000 / 1500 → aşıldı
      await tester.pump();
      expect(tester.widgetList<ColoredBox>(find.byKey(const ValueKey('budget-fill'))).first.color, c.danger);
      expect(find.text('Limit ${fmtMoney(500)} aşıldı'), findsOneWidget);
    });
  });
}
