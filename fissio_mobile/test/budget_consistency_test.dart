import 'package:fissio_mobile/budgets.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/budgets_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Kural: toplam aylık bütçe, kategori limitlerinin toplamından küçük olamaz (eşit olabilir).

Budget _b(int cat, double limit, {String profile = 'p1'}) =>
    Budget(profileUid: profile, categoryId: cat, categoryName: cat == 0 ? kTotalBudgetName : 'K$cat', limit: limit);

BudgetLimitCheck _check(List<Budget> budgets, int cat, double limit, {String profile = 'p1'}) =>
    checkBudgetLimit(budgets: budgets, profileUid: profile, categoryId: cat, newLimit: limit);

void main() {
  group('checkBudgetLimit (saf)', () {
    test('toplam yoksa kategori limitleri serbest', () {
      expect(_check([_b(1, 100)], 2, 99999).ok, isTrue);
    });

    test('toplam kategori toplamına eşit olabilir; altına düşürmek reddedilir', () {
      final bs = [_b(0, 5000), _b(1, 2000), _b(2, 3000)];
      expect(_check(bs, 0, 5000).ok, isTrue, reason: 'eşit serbest');
      final r = _check(bs, 0, 4999.99);
      expect(r.issue, BudgetLimitIssue.totalBelowCategories);
      expect(r.categorySum, 5000);
      expect(r.message, contains('küçük olamaz'));
    });

    test('kategori eklemek/artırmak toplamı aşıyorsa reddedilir ve eşitleme tutarı önerilir', () {
      final bs = [_b(0, 5000), _b(1, 2000)];
      expect(_check(bs, 2, 3000).ok, isTrue, reason: 'tam sınır');
      final r = _check(bs, 2, 3000.01);
      expect(r.issue, BudgetLimitIssue.categoriesExceedTotal);
      expect(r.suggestedTotal, 5000.01);
      // Mevcut kategoriyi artırma: eski değeri toplamdan düşülür.
      expect(_check(bs, 1, 5000).ok, isTrue);
      expect(_check(bs, 1, 5000.01).issue, BudgetLimitIssue.categoriesExceedTotal);
    });

    test('profil izolasyonu: başka profilin limitleri sayılmaz', () {
      final bs = [_b(0, 1000, profile: 'p2'), _b(1, 900, profile: 'p2'), _b(0, 5000)];
      expect(_check(bs, 1, 4000).ok, isTrue);
    });

    test('zaten tutarsız veri: yalnızca durumu kötüleştiren değişiklik reddedilir', () {
      final bs = [_b(0, 1000), _b(1, 800), _b(2, 700)]; // toplam 1500 > 1000 (fazla 500)
      expect(_check(bs, 2, 100).ok, isTrue, reason: 'kategoriyi düşürmek serbest');
      expect(_check(bs, 1, 800).ok, isTrue, reason: 'aynı değer kötüleştirmez');
      expect(_check(bs, 1, 900).issue, BudgetLimitIssue.categoriesExceedTotal, reason: 'fazlayı artırır');
      expect(_check(bs, 0, 1200).ok, isTrue, reason: 'toplamı yükseltmek serbest (hâlâ eksik olsa da)');
      expect(_check(bs, 0, 900).issue, BudgetLimitIssue.totalBelowCategories, reason: 'toplamı daha da düşürmek');
    });

    test('kuruş hassasiyeti: kayan nokta sınırı kaydırmaz', () {
      final bs = [_b(0, 0.3), _b(1, 0.1)];
      expect(_check(bs, 2, 0.2).ok, isTrue); // 0.1 + 0.2 == 0.3
    });
  });

  group('AppState.setBudget', () {
    late Harness h;
    setUp(() => h = Harness());

    test('toplamı kategori toplamının altına düşürmek reddedilir; durum değişmez', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(kTotalBudgetCategoryId, 5000);
      await h.app.setBudget(1, 2000);
      await h.app.setBudget(2, 3000);
      await expectLater(
        h.app.setBudget(kTotalBudgetCategoryId, 4000),
        throwsA(isA<BudgetLimitException>().having((e) => e.check.issue, 'issue', BudgetLimitIssue.totalBelowCategories)),
      );
      expect(h.app.budgetProgress.first.budget.limit, 5000);
      expect(h.backend.user('ali@x.co').budgets.firstWhere((b) => b['category_id'] == null)['monthly_limit'], 5000);
    });

    test('kategori limiti toplamı aşarsa reddedilir; raiseTotal toplamı eşitleyip kaydeder', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(kTotalBudgetCategoryId, 5000);
      await h.app.setBudget(1, 2000);
      await expectLater(h.app.setBudget(2, 3500), throwsA(isA<BudgetLimitException>()));
      expect(h.app.budgets.where((b) => b.categoryId == 2), isEmpty);

      await h.app.setBudget(2, 3500, raiseTotal: true);
      final byCat = {for (final b in h.app.budgets) b.categoryId: b.limit};
      expect(byCat, {0: 5500.0, 1: 2000.0, 2: 3500.0});
    });

    test('çevrimdışı kuyrukta ve senkron kapalıyken de uygulanır', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(kTotalBudgetCategoryId, 1000);
      h.backend.offline = true;
      await expectLater(h.app.setBudget(1, 1500), throwsA(isA<BudgetLimitException>()));
      await h.app.setBudget(1, 600); // kuyruğa yazılır (pending)
      await expectLater(h.app.setBudget(2, 500), throwsA(isA<BudgetLimitException>()), reason: 'bekleyen limit de sayılır');
      h.backend.offline = false;
      await h.app.setSyncEnabled(false);
      await expectLater(h.app.setBudget(3, 500), throwsA(isA<BudgetLimitException>()));
    });

    test('silme her zaman serbest; toplam yoksa kategori sınırsız', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(1, 9000);
      await h.app.setBudget(kTotalBudgetCategoryId, 9000);
      await h.app.removeBudget(1);
      await h.app.removeBudget(kTotalBudgetCategoryId);
      await h.app.setBudget(2, 123456);
      expect(h.app.budgets.single.categoryId, 2);
    });
  });

  group('Bütçe sayfası', () {
    testWidgets('toplam yetersizken diyalog toplamı yükseltmeyi önerir; vazgeçince değişmez, onaylayınca yükselir', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = Harness();
      await tester.runAsync(() async {
        await h.signIn('ali@x.co');
        await h.app.setBudget(kTotalBudgetCategoryId, 1000);
      });
      final catId = h.app.categories.first.id;
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: BudgetsPage(app: h.app)));
      await tester.pump();

      Future<void> enter(String v) async {
        await tester.tap(find.byKey(ValueKey('budget-$catId')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), v);
        await tester.tap(find.text('Kaydet'));
        await tester.pumpAndSettle();
      }

      await enter('1500');
      expect(find.text('Toplam bütçe yetersiz'), findsOneWidget);
      expect(find.textContaining('1.500,00 ₺'), findsWidgets);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(h.app.budgets.map((b) => b.categoryId), [kTotalBudgetCategoryId]);

      await enter('1500');
      await tester.runAsync(() async {
        await tester.tap(find.text('Toplamı yükselt'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      final byCat = {for (final b in h.app.budgets) b.categoryId: b.limit};
      expect(byCat, {kTotalBudgetCategoryId: 1500.0, catId: 1500.0});
    });

    testWidgets('toplamı kategori toplamının altına düşürmek hata mesajıyla reddedilir (diyalog yok)', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = Harness();
      await tester.runAsync(() async {
        await h.signIn('ali@x.co');
        await h.app.setBudget(kTotalBudgetCategoryId, 5000);
        await h.app.setBudget(h.app.categories.first.id, 2000);
      });
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: BudgetsPage(app: h.app)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('budget-total')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1000');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Toplam bütçe yetersiz'), findsNothing);
      expect(h.app.budgetProgress.first.budget.limit, 5000);
    });
  });
}
