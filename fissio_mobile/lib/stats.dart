import 'models.dart';
import 'theme.dart' show kMonthNames;

/// Özet ekranındaki dönem seçici (1H / 1A / 3A / 1Y).
enum HomePeriod {
  week('1H', 7, 'geçen haftaya'),
  month('1A', 30, 'geçen aya'),
  quarter('3A', 90, 'önceki 3 aya'),
  year('1Y', 365, 'geçen yıla');

  const HomePeriod(this.label, this.days, this.compareLabel);

  final String label;
  final int days;

  /// "… göre" ifadesinin başı: "+%12 geçen aya göre".
  final String compareLabel;
}

class CategoryShare {
  const CategoryShare({
    required this.id,
    required this.name,
    required this.total,
    required this.share,
  });
  final int id;
  final String name;
  final double total;

  /// 0..1 arası pay.
  final double share;
}

class HomeStats {
  const HomeStats({
    required this.total,
    required this.count,
    required this.previousTotal,
    required this.buckets,
    required this.categories,
    required this.highest,
  });

  final double total;
  final int count;
  final double previousTotal;

  /// Dönemi 4 eşit dilime bölen toplamlar (eskiden yeniye).
  final List<double> buckets;

  /// Toplamı büyükten küçüğe sıralı kategori dağılımı.
  final List<CategoryShare> categories;
  final Expense? highest;

  /// Önceki eşit uzunluktaki döneme göre yüzde değişim; önceki dönem 0 ise null.
  double? get changePct =>
      previousTotal <= 0 ? null : (total - previousTotal) / previousTotal * 100;
}

DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// Seçili dönemin ([bugün-days+1, bugün]) ve bir önceki eşit uzunluktaki dönemin özetini çıkarır.
HomeStats computeHomeStats(
  List<Expense> expenses,
  HomePeriod period, {
  DateTime? now,
}) {
  final today = _day(now ?? DateTime.now());
  final days = period.days;
  var total = 0.0;
  var prev = 0.0;
  var count = 0;
  final buckets = List<double>.filled(4, 0);
  final cats = <int, ({String name, double total})>{};
  Expense? highest;

  for (final e in expenses) {
    final ago = today.difference(_day(e.date)).inDays;
    if (ago < 0) continue; // gelecek tarihli fişler dönemlere girmez
    if (ago < days) {
      total += e.amount;
      count++;
      buckets[3 - (ago * 4 ~/ days)] += e.amount;
      final cur = cats[e.categoryId];
      cats[e.categoryId] = (
        name: e.categoryName,
        total: (cur?.total ?? 0) + e.amount,
      );
      if (highest == null || e.amount > highest.amount) highest = e;
    } else if (ago < days * 2) {
      prev += e.amount;
    }
  }

  final sorted = cats.entries.toList()
    ..sort((a, b) => b.value.total.compareTo(a.value.total));
  final categories = [
    for (final c in sorted)
      CategoryShare(
        id: c.key,
        name: c.value.name,
        total: c.value.total,
        share: total <= 0 ? 0 : c.value.total / total,
      ),
  ];

  return HomeStats(
    total: total,
    count: count,
    previousTotal: prev,
    buckets: buckets,
    categories: categories,
    highest: highest,
  );
}

/// "+%12" / "-%5" / "%0" biçimi.
String fmtChange(double pct) {
  final r = pct.round();
  if (r == 0) return '%0';
  return '${r > 0 ? '+' : '-'}%${r.abs()}';
}

/// Fişler listesinin aya göre grubu.
class MonthGroup {
  MonthGroup(this.year, this.month, this.items);
  final int year;
  final int month;
  final List<Expense> items;

  double get total => items.fold(0.0, (s, e) => s + e.amount);

  /// "Bu ay" ya da "Ekim 2026".
  String title(DateTime now) => (year == now.year && month == now.month)
      ? 'Bu ay'
      : '${kMonthNames[month - 1]} $year';
}

/// Sıralı listeyi (verilen sırayı koruyarak) ardışık aylara böler.
List<MonthGroup> groupByMonth(List<Expense> sorted) {
  final groups = <MonthGroup>[];
  for (final e in sorted) {
    if (groups.isEmpty ||
        groups.last.year != e.date.year ||
        groups.last.month != e.date.month) {
      groups.add(MonthGroup(e.date.year, e.date.month, []));
    }
    groups.last.items.add(e);
  }
  return groups;
}
