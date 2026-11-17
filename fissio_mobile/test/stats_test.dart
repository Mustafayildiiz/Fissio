import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/stats.dart';
import 'package:flutter_test/flutter_test.dart';

Expense _e(int id, double amount, DateTime date, {int cat = 1, String catName = 'Market'}) =>
    Expense(
      id: id,
      merchant: 'M$id',
      amount: amount,
      date: date,
      categoryId: cat,
      categoryName: catName,
      note: '',
      items: const [],
    );

void main() {
  final now = DateTime(2026, 11, 17);

  test('dönem toplamı, adedi ve en yüksek fişi hesaplar', () {
    final s = computeHomeStats([
      _e(1, 100, DateTime(2026, 11, 17)), // bugün
      _e(2, 250, DateTime(2026, 11, 1)), // 16 gün önce
      _e(3, 40, DateTime(2026, 9, 1)), // 30 günden eski
    ], HomePeriod.month, now: now);
    expect(s.total, 350);
    expect(s.count, 2);
    expect(s.highest!.id, 2);
  });

  test('önceki eşit uzunluktaki dönemle yüzde değişim', () {
    final s = computeHomeStats([
      _e(1, 150, DateTime(2026, 11, 10)), // bu dönem
      _e(2, 100, DateTime(2026, 10, 10)), // 38 gün önce = önceki dönem
    ], HomePeriod.month, now: now);
    expect(s.previousTotal, 100);
    expect(s.changePct, closeTo(50, 1e-9));
    expect(fmtChange(s.changePct!), '+%50');
  });

  test('önceki dönem boşsa değişim yok', () {
    final s = computeHomeStats([_e(1, 10, now)], HomePeriod.week, now: now);
    expect(s.changePct, isNull);
  });

  test('gelecek tarihli fişler dönemlere girmez', () {
    final s = computeHomeStats([_e(1, 99, DateTime(2026, 12, 1))], HomePeriod.year, now: now);
    expect(s.total, 0);
    expect(s.count, 0);
  });

  test('4 dilim eskiden yeniye; en yeni dilim sonda', () {
    // 30 günlük dönem: ago 0..7 → son dilim, 22..29 → ilk dilim.
    final s = computeHomeStats([
      _e(1, 1, DateTime(2026, 11, 17)),
      _e(2, 2, DateTime(2026, 11, 17).subtract(const Duration(days: 29))),
    ], HomePeriod.month, now: now);
    expect(s.buckets, [2, 0, 0, 1]);
  });

  test('kategori dağılımı büyükten küçüğe ve paylar toplamı 1', () {
    final s = computeHomeStats([
      _e(1, 30, now, cat: 1, catName: 'Market'),
      _e(2, 60, now, cat: 2, catName: 'Ulaşım'),
      _e(3, 10, now, cat: 1, catName: 'Market'),
    ], HomePeriod.month, now: now);
    expect(s.categories.map((c) => c.name), ['Ulaşım', 'Market']);
    expect(s.categories.first.share, closeTo(0.6, 1e-9));
    expect(s.categories.fold<double>(0, (a, c) => a + c.share), closeTo(1, 1e-9));
  });

  test('değişim biçimi', () {
    expect(fmtChange(12.4), '+%12');
    expect(fmtChange(-5.2), '-%5');
    expect(fmtChange(0.2), '%0');
  });

  test('aya göre gruplama ardışık aylara böler ve ay toplamını verir', () {
    final groups = groupByMonth([
      _e(1, 10, DateTime(2026, 11, 5)),
      _e(2, 20, DateTime(2026, 11, 1)),
      _e(3, 5, DateTime(2026, 10, 28)),
    ]);
    expect(groups.length, 2);
    expect(groups[0].total, 30);
    expect(groups[0].title(now), 'Bu ay');
    expect(groups[1].title(now), 'Ekim 2026');
  });
}
