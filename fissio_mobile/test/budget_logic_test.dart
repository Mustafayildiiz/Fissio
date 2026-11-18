import 'package:fissio_mobile/budgets.dart';
import 'package:fissio_mobile/models.dart';
import 'package:flutter_test/flutter_test.dart';

Expense _e(
  int id,
  double amount,
  DateTime date, {
  int cat = 1,
  String profile = 'p1',
  String catName = 'Market / Gıda',
}) => Expense(
  id: id,
  merchant: 'M$id',
  amount: amount,
  date: date,
  categoryId: cat,
  categoryName: catName,
  note: '',
  items: const [],
  clientUid: 'u$id',
  profileUid: profile,
);

Budget _b(int cat, double limit, {String profile = 'p1', String name = 'Market / Gıda'}) =>
    Budget(profileUid: profile, categoryId: cat, categoryName: name, limit: limit);

void main() {
  final now = DateTime(2026, 5, 15);

  group('eşikler: %80 sarı, %100 kırmızı', () {
    test('sınır değerleri (kuruş hassasiyetiyle)', () {
      expect(budgetLevel(0, 8000), BudgetLevel.ok);
      expect(budgetLevel(6399.99, 8000), BudgetLevel.ok); // %79,99
      expect(budgetLevel(6400, 8000), BudgetLevel.warning); // tam %80
      expect(budgetLevel(7999.99, 8000), BudgetLevel.warning);
      expect(budgetLevel(8000, 8000), BudgetLevel.exceeded); // tam %100
      expect(budgetLevel(12000, 8000), BudgetLevel.exceeded);
      expect(budgetLevel(0.1 + 0.2, 0.3), BudgetLevel.exceeded); // kayan nokta sınırı kaydırmaz
      expect(budgetLevel(10, 0), BudgetLevel.ok); // limit yok
    });
  });

  group('harcama hesabı', () {
    test('fiş tutarı, fişin kendi kategorisi, yalnızca bu ay ve bu profil', () {
      final expenses = [
        _e(1, 500, DateTime(2026, 5, 3)),
        _e(2, 300, DateTime(2026, 5, 31)),
        _e(3, 400, DateTime(2026, 4, 30)), // önceki ay
        _e(4, 999, DateTime(2026, 5, 10), cat: 2, catName: 'Restoran / Kafe'), // başka kategori
        _e(5, 700, DateTime(2026, 5, 10), profile: 'p2'), // başka profil
        _e(6, 50, DateTime(2025, 5, 10)), // geçen yılın aynı ayı
      ];
      final p = computeBudgetProgress(expenses, [_b(1, 1000), _b(2, 500, name: 'Restoran / Kafe')], 'p1', now);
      expect(p.length, 2);
      final market = p.firstWhere((x) => x.budget.categoryId == 1);
      expect(market.spent, 800);
      expect(market.level, BudgetLevel.warning);
      expect(market.ratio, closeTo(.8, 1e-9));
      final cafe = p.firstWhere((x) => x.budget.categoryId == 2);
      expect(cafe.spent, 999);
      expect(cafe.level, BudgetLevel.exceeded);
    });

    test('başka profilin bütçesi satıra girmez', () {
      final p = computeBudgetProgress(
        [_e(1, 100, DateTime(2026, 5, 3), profile: 'p2')],
        [_b(1, 1000, profile: 'p2')],
        'p1',
        now,
      );
      expect(p, isEmpty);
    });

    test('aylık toplam: profil + takvim ayı', () {
      final expenses = [
        _e(1, 10, DateTime(2026, 5, 1)),
        _e(2, 20.5, DateTime(2026, 5, 31)),
        _e(3, 5, DateTime(2026, 4, 30)),
        _e(4, 7, DateTime(2026, 5, 2), profile: 'p2'),
      ];
      expect(monthTotalFor(expenses, 'p1', now), 30.5);
      expect(monthTotalFor(expenses, 'p2', now), 7);
      expect(monthTotalFor(expenses, null, now), 37.5);
    });
  });

  group('bildirim tetikleme: her eşik, ay başına bir kez', () {
    List<BudgetProgress> progress(double spent, {String profile = 'p1'}) =>
        [BudgetProgress(budget: _b(1, 1000, profile: profile), spent: spent)];

    test('%80 aşılınca bir bildirim; aynı ay tekrarında yok', () {
      var r = evaluateBudgetAlerts(progress(799.99), {}, now);
      expect(r.alerts, isEmpty);

      r = evaluateBudgetAlerts(progress(800), r.sent, now);
      expect(r.alerts.length, 1);
      expect(r.alerts.single.threshold, 80);
      expect(r.alerts.single.title, contains('%80'));

      // Aynı eşikte yeni fiş: spam yok.
      final again = evaluateBudgetAlerts(progress(900), r.sent, now);
      expect(again.alerts, isEmpty);
    });

    test('%100 aşılınca ayrı bir bildirim, sonra tekrar yok', () {
      var r = evaluateBudgetAlerts(progress(850), {}, now);
      expect(r.alerts.single.threshold, 80);
      r = evaluateBudgetAlerts(progress(1000), r.sent, now);
      expect(r.alerts.single.threshold, 100);
      expect(r.alerts.single.title, contains('aşıldı'));
      r = evaluateBudgetAlerts(progress(1500), r.sent, now);
      expect(r.alerts, isEmpty);
    });

    test('tek fiş her iki eşiği birden geçerse yalnızca %100 bildirimi gider, iki eşik de işaretlenir', () {
      var r = evaluateBudgetAlerts(progress(1200), {}, now);
      expect(r.alerts.length, 1);
      expect(r.alerts.single.threshold, 100);
      expect(r.sent, containsAll([budgetAlertKey(now, 'p1', 1, 80), budgetAlertKey(now, 'p1', 1, 100)]));
      // Harcama sonradan %90'a düşse bile %80 bildirimi geri gelmez.
      r = evaluateBudgetAlerts(progress(900), r.sent, now);
      expect(r.alerts, isEmpty);
    });

    test('yeni ay eşikleri yeniden silahlandırır ve eski ay anahtarları temizlenir', () {
      var r = evaluateBudgetAlerts(progress(1000), {}, now);
      expect(r.alerts.length, 1);
      final june = DateTime(2026, 6, 2);
      r = evaluateBudgetAlerts(progress(900), r.sent, june);
      expect(r.alerts.single.threshold, 80);
      expect(r.sent.every((k) => k.startsWith('2026-06|')), isTrue);
    });

    test('profiller birbirinden bağımsız anahtarlanır', () {
      final r1 = evaluateBudgetAlerts(progress(900, profile: 'p1'), {}, now);
      expect(r1.alerts.length, 1);
      final r2 = evaluateBudgetAlerts(progress(900, profile: 'p2'), r1.sent, now);
      expect(r2.alerts.length, 1, reason: 'p1 bildirimi p2 için bildirimi engellemez');
    });

    test('bildirim kimliği kararlı ve eşiğe göre farklı', () {
      expect(budgetNotificationId('p1', 1, 80), budgetNotificationId('p1', 1, 80));
      expect(budgetNotificationId('p1', 1, 80), isNot(budgetNotificationId('p1', 1, 100)));
      expect(budgetNotificationId('p1', 1, 80), greaterThanOrEqualTo(0));
    });
  });

  test('parseMoneyInput', () {
    expect(parseMoneyInput('8.000'), 8000);
    expect(parseMoneyInput('8000,50'), 8000.5);
    expect(parseMoneyInput('8000.50'), 8000.5);
    expect(parseMoneyInput('3000 TL'), 3000);
    expect(parseMoneyInput('1.234,5'), 1234.5);
    expect(parseMoneyInput(''), isNull);
    expect(parseMoneyInput('abc'), isNull);
  });
}
