import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/recurring.dart';
import 'package:flutter_test/flutter_test.dart';

Expense _e(
  int id,
  String merchant,
  double amount,
  DateTime date, {
  int day = 0,
  bool remind = true,
  int cat = 7,
  String profile = 'p1',
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
  profileUid: profile,
  recurringDay: day,
  recurringRemind: remind,
);

void main() {
  final today = DateTime(2026, 5, 10);

  test('seri anahtarı sunucudakiyle aynı (Türkçe katlama, noktalama, kategori)', () {
    // Aynı vektörler services/expense/budgets_test.go içinde.
    expect(recurringSeriesKey('Enerjisa  Elektrik', 7), recurringSeriesKey('ENERJISA elektrik.', 7));
    expect(recurringSeriesKey('Enerjisa', 7), isNot(recurringSeriesKey('Enerjisa', 8)));
    expect(recurringSeriesKey('', 3), '3|');
    expect(recurringSeriesKey('İş Bankası', 1), '1|is bankasi');
  });

  group('aylık sabit gider projeksiyonu', () {
    test('her seri bir kez sayılır: en son fişteki tutar', () {
      final p = buildRecurring([
        _e(1, 'Enerjisa', 300, DateTime(2026, 3, 25), day: 25),
        _e(2, 'ENERJISA', 350, DateTime(2026, 4, 25), day: 25),
        _e(3, 'Enerjisa', 400, DateTime(2026, 5, 5), day: 25),
        _e(4, 'Ev sahibi', 12000, DateTime(2026, 4, 1), day: 1, remind: false),
        _e(5, 'Migros', 80, DateTime(2026, 5, 2)), // tekrarlamaz
      ], today);
      expect(p.items.length, 2);
      expect(p.monthlyTotal, 12400);
      final el = p.items.firstWhere((i) => i.merchant.toLowerCase() == 'enerjisa');
      expect(el.amount, 400);
      expect(el.lastExpenseId, 3);
    });

    test('en son fişte işaret kaldırıldıysa seri biter; profiller ayrı seridir', () {
      final p = buildRecurring([
        _e(1, 'Netflix', 100, DateTime(2026, 3, 3), day: 3),
        _e(2, 'Netflix', 100, DateTime(2026, 4, 3)), // işaret kaldırıldı
        _e(3, 'Netflix', 120, DateTime(2026, 4, 3), day: 3, profile: 'p2'),
      ], today);
      expect(p.items.length, 1);
      expect(p.items.single.profileUid, 'p2');
      expect(p.monthlyTotal, 120);
    });

    test('tekrarlayan fiş yoksa boş projeksiyon', () {
      final p = buildRecurring([_e(1, 'Migros', 50, DateTime(2026, 5, 1))], today);
      expect(p.items, isEmpty);
      expect(p.monthlyTotal, 0);
    });
  });

  group('sonraki ödeme tarihi', () {
    test('bu ay için fiş girildiyse gelecek ay; girilmediyse ve gün geçmediyse bu ay', () {
      expect(nextDueDate(25, DateTime(2026, 5, 5), today), DateTime.utc(2026, 6, 25));
      expect(nextDueDate(25, DateTime(2026, 4, 25), today), DateTime.utc(2026, 5, 25));
      expect(nextDueDate(10, DateTime(2026, 4, 10), today), DateTime.utc(2026, 5, 10), reason: 'bugün ödeme günü');
      expect(nextDueDate(3, DateTime(2026, 4, 3), today), DateTime.utc(2026, 6, 3), reason: 'bu ayın 3\'ü geçti');
    });

    test('ayın gün sayısını aşan gün ayın son gününe çekilir; yıl dönümü', () {
      expect(nextDueDate(31, DateTime(2026, 1, 31), DateTime(2026, 2, 2)), DateTime.utc(2026, 2, 28));
      expect(nextDueDate(31, DateTime(2027, 12, 31), DateTime(2028, 2, 2)), DateTime.utc(2028, 2, 29));
      expect(nextDueDate(30, DateTime(2026, 12, 30), DateTime(2026, 12, 31)), DateTime.utc(2027, 1, 30));
    });
  });

  group('yaklaşan ödemeler ve hatırlatıcılar', () {
    final items = buildRecurring([
      _e(1, 'Enerjisa', 400, DateTime(2026, 4, 25), day: 25),
      _e(2, 'Ev sahibi', 12000, DateTime(2026, 4, 1), day: 1, remind: false),
      _e(3, 'Internet', 300, DateTime(2026, 4, 12), day: 12),
    ], today).items;

    test('30 gün içindekiler en yakın önce listelenir', () {
      final up = upcomingPaymentsOf(items, today);
      expect(up.map((i) => i.merchant), ['Internet', 'Enerjisa', 'Ev sahibi']);
      expect(up.first.daysUntil(today), 2);
      expect(upcomingPaymentsOf(items, today, days: 5).map((i) => i.merchant), ['Internet']);
    });

    test('3 gün kala ve ödeme gününde hatırlatıcı; geçmiş ve hatırlatıcısız seriler atlanır', () {
      // Internet: ödeme 12 Mayıs -> "3 gün kala" 9 Mayıs (geçmişte, atlanır), ödeme günü 12 Mayıs 09:00.
      final plans = planReminders(items, DateTime(2026, 5, 10, 8));
      final byTitle = {for (final p in plans) p.title: p};
      expect(byTitle.keys.any((t) => t.contains('Internet') && t.startsWith('Bugün')), isTrue);
      expect(byTitle.keys.any((t) => t.contains('Internet') && t.startsWith('Ödeme yaklaşıyor')), isFalse);
      // Enerjisa: 25 Mayıs -> 22 Mayıs 09:00 ve 25 Mayıs 09:00.
      final en = plans.where((p) => p.title.contains('Enerjisa')).toList()..sort((a, b) => a.when.compareTo(b.when));
      expect(en.map((p) => p.when), [DateTime(2026, 5, 22, 9), DateTime(2026, 5, 25, 9)]);
      expect(en.first.body, contains('3 gün sonra'));
      // Kira: hatırlatıcı kapalı.
      expect(plans.any((p) => p.title.contains('Ev sahibi')), isFalse);
      // Kimlikler benzersiz ve kararlı.
      expect({for (final p in plans) p.id}.length, plans.length);
      final again = planReminders(items, DateTime(2026, 5, 10, 8));
      expect(again.map((p) => p.id).toList(), plans.map((p) => p.id).toList());
    });

    test('ödeme günü saatinden sonra bugünün hatırlatıcısı planlanmaz', () {
      final plans = planReminders(items, DateTime(2026, 5, 12, 10));
      expect(plans.any((p) => p.title.contains('Internet')), isFalse);
    });
  });
}
