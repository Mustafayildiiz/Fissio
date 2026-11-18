import 'budgets.dart' show stableId;
import 'models.dart';
import 'receipt_parser/normalize.dart' show foldTR;
import 'theme.dart' show fmtDate, fmtMoney;

/// Tekrarlayan giderler ("Her ay tekrarlanır"): seri, projeksiyon, yaklaşan ödemeler ve hatırlatıcı planı.
/// Sunucudaki `recurring.go` ile aynı kurallar (offline/yerel fişler de dahil olsun diye istemcide de hesaplanır;
/// ortak test vektörleri: services/expense/recurring_test.go <-> test/recurring_logic_test.dart):
///
/// Çift sayım önlemi: aynı gider her ay yeni fiş olarak girilir (Ocak ve Şubat elektrik faturası). Projeksiyon fiş
/// başına değil SERİ başınadır. Seri anahtarı = kategori + normalize işletme adı (profil başına). Serinin güncel
/// hali o anahtardaki EN SON fiştir (tarih, sonra id). En son fiş işaretliyse seri aktiftir ve ödeme günü / türü o
/// fişten gelir; işaretsizse seri bitmiş sayılır (kullanıcı işareti kaldırdı).
///
/// Sabit / değişken: kira, abonelik gibi SABİT giderde beklenen tutar son fişin tutarıdır. Elektrik, su, doğalgaz
/// gibi DEĞİŞKEN faturada tutar her ay değişir; beklenen tutar serinin son 3 AYLIK fiş tutarlarının hareketli
/// ortalamasıdır (min-max aralığıyla). Geçmişte 2'den az ay varsa kullanıcının girdiği tahmini tutar, o da yoksa son
/// fiş tutarı kullanılır. Ayda birden fazla fiş varsa o ayın en son fişi sayılır (çift tarama tutarı ikiye katlamaz).
///
/// Ödendi / gerçekleşti: serinin içinde bulunulan ayda bir fişi varsa o ayın kalemi "ödendi"dir ve projeksiyona
/// TAHMİN değil gerçek tutar girer; yoksa projeksiyona beklenen tutar girer.

/// Hareketli ortalamanın ay sayısı.
const kRecurringWindow = 3;

class RecurringItem {
  const RecurringItem({
    required this.seriesKey,
    required this.profileUid,
    required this.merchant,
    required this.categoryId,
    required this.categoryName,
    required this.amount,
    required this.day,
    required this.remind,
    required this.lastExpenseId,
    required this.lastDate,
    required this.nextDue,
    this.kind = RecurringKind.fixed,
    this.estimate = 0,
    double? expected,
    double? minAmount,
    double? maxAmount,
    this.historyCount = 1,
    this.paidThisMonth = false,
    this.actualAmount = 0,
    double? monthAmount,
  }) : expected = expected ?? amount,
       minAmount = minAmount ?? expected ?? amount,
       maxAmount = maxAmount ?? expected ?? amount,
       monthAmount = monthAmount ?? (paidThisMonth ? actualAmount : (expected ?? amount));
  final String seriesKey;
  final String profileUid;
  final String merchant;
  final int categoryId;
  final String categoryName;

  /// Son fişin tutarı.
  final double amount;
  final int day;
  final bool remind;
  final int lastExpenseId;
  final DateTime lastDate;
  final DateTime nextDue;

  /// Sabit mi, değişken fatura mı; değişken için kullanıcının tahmini tutarı (0 = yok).
  final RecurringKind kind;
  final double estimate;

  /// Bir sonraki (ya da bu ayki ödenmemiş) fatura için beklenen tutar ve tahmini aralık (sabit giderde üçü de
  /// aynıdır). [historyCount] hareketli ortalamaya giren ay sayısıdır.
  final double expected;
  final double minAmount;
  final double maxAmount;
  final int historyCount;

  /// Bu ay serinin fişi girilmiş (ödendi / gerçekleşti) ve o fişin tutarı.
  final bool paidThisMonth;
  final double actualAmount;

  /// Bu ayın projeksiyonuna giren tutar: ödendiyse gerçek, değilse beklenen.
  final double monthAmount;

  bool get isVariable => kind == RecurringKind.variable;

  /// Beklenen tutarın bir aralığı var mı (değişken fatura, geçmişte birden çok ay).
  bool get hasRange => isVariable && historyCount >= 2 && maxAmount > minAmount;

  String get title => merchant.isEmpty ? categoryName : merchant;

  /// Bugünden [nextDue]'ya kalan gün (0 = bugün).
  int daysUntil(DateTime today) => _day(nextDue).difference(_day(today)).inDays;
}

class RecurringProjection {
  const RecurringProjection(
    this.items,
    this.monthlyTotal, {
    this.paidTotal = 0,
    this.remainingTotal = 0,
    this.minTotal = 0,
    this.maxTotal = 0,
  });
  final List<RecurringItem> items;

  /// "Aylık Sabit Gider Projeksiyonu": bu ay için ödenenlerin gerçek + ödenmemişlerin beklenen tutarları toplamı.
  final double monthlyTotal;

  /// [monthlyTotal]'ın ödenen (gerçek) ve kalan (beklenen) parçaları; [minTotal]/[maxTotal] tahmini aralık.
  final double paidTotal;
  final double remainingTotal;
  final double minTotal;
  final double maxTotal;

  bool get hasRange => maxTotal > minTotal;
}

DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// `kategori|küçük harf, Türkçe katlanmış, harf/rakam jetonları`; işletme adı boşsa yalnızca kategori.
String recurringSeriesKey(String merchant, int categoryId) {
  final toks = foldTR(merchant).split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)).where((t) => t.isNotEmpty);
  return '$categoryId|${toks.join(' ')}';
}

DateTime _clampedDate(int y, int m, int day) {
  final base = DateTime.utc(y, m, 1); // ay taşmasını normalize eder
  final n = DateTime.utc(base.year, base.month + 1, 0).day;
  return DateTime.utc(base.year, base.month, day > n ? n : day);
}

/// Serinin bir sonraki ödeme tarihi: bu ayın ödeme günü (henüz geçmediyse ve bu ay için fiş girilmediyse),
/// aksi halde gelecek ayın ödeme günü. Ayın gün sayısını aşan gün (31 Şubat) ayın son gününe çekilir.
DateTime nextDueDate(int day, DateTime lastExpenseDate, DateTime today) {
  final t = _day(today);
  var due = _clampedDate(t.year, t.month, day);
  final paidThisMonth = lastExpenseDate.year == t.year && lastExpenseDate.month == t.month;
  if (paidThisMonth || due.isBefore(t)) due = _clampedDate(t.year, t.month + 1, day);
  return due;
}

double _r2(double v) => (v * 100).round() / 100;

bool _newer(Expense a, Expense b) {
  final c = _day(a.date).compareTo(_day(b.date));
  return c > 0 || (c == 0 && a.id > b.id);
}

RecurringProjection buildRecurring(List<Expense> expenses, DateTime today) {
  final groups = <String, List<Expense>>{};
  for (final e in expenses) {
    groups.putIfAbsent('${e.profileUid}#${recurringSeriesKey(e.merchant, e.categoryId)}', () => []).add(e);
  }
  final items = <RecurringItem>[];
  var monthly = 0.0, paidT = 0.0, remainT = 0.0, minT = 0.0, maxT = 0.0;
  final curKey = today.year * 12 + today.month;
  for (final g in groups.values) {
    var latest = g.first;
    for (final e in g.skip(1)) {
      if (_newer(e, latest)) latest = e;
    }
    if (!latest.isRecurring) continue;
    // Ay bazlı geçmiş: her ayın en son fişi, en yeni ay önce.
    final byMonth = <int, Expense>{};
    for (final e in g) {
      final k = e.date.year * 12 + e.date.month;
      final cur = byMonth[k];
      if (cur == null || _newer(e, cur)) byMonth[k] = e;
    }
    final months = byMonth.values.toList()..sort((a, b) => _newer(a, b) ? -1 : 1);
    final thisMonth = byMonth[curKey];
    final paid = thisMonth != null;

    var expected = _r2(latest.amount);
    var minA = expected, maxA = expected;
    var used = months.length;
    if (latest.recurringKind == RecurringKind.variable) {
      final w = months.take(kRecurringWindow).toList();
      if (w.length >= 2) {
        final sum = w.fold<double>(0, (s, e) => s + e.amount);
        expected = _r2(sum / w.length);
        minA = _r2(w.map((e) => e.amount).reduce((a, b) => a < b ? a : b));
        maxA = _r2(w.map((e) => e.amount).reduce((a, b) => a > b ? a : b));
        used = w.length;
      } else if (latest.recurringEstimate > 0) {
        expected = minA = maxA = _r2(latest.recurringEstimate);
        used = w.length;
      }
    }
    final actual = paid ? _r2(thisMonth.amount) : 0.0;
    final monthAmount = paid ? actual : expected;
    items.add(
      RecurringItem(
        seriesKey: recurringSeriesKey(latest.merchant, latest.categoryId),
        profileUid: latest.profileUid,
        merchant: latest.merchant,
        categoryId: latest.categoryId,
        categoryName: latest.categoryName,
        amount: _r2(latest.amount),
        day: latest.recurringDay,
        remind: latest.recurringRemind,
        lastExpenseId: latest.id,
        lastDate: latest.date,
        nextDue: nextDueDate(latest.recurringDay, latest.date, today),
        kind: latest.recurringKind,
        estimate: _r2(latest.recurringEstimate),
        expected: expected,
        minAmount: minA,
        maxAmount: maxA,
        historyCount: used,
        paidThisMonth: paid,
        actualAmount: actual,
        monthAmount: monthAmount,
      ),
    );
    monthly += monthAmount;
    if (paid) {
      paidT += actual;
      minT += actual;
      maxT += actual;
    } else {
      remainT += expected;
      minT += minA;
      maxT += maxA;
    }
  }
  items.sort((a, b) {
    var c = a.nextDue.compareTo(b.nextDue);
    if (c != 0) return c;
    c = a.profileUid.compareTo(b.profileUid);
    return c != 0 ? c : a.seriesKey.compareTo(b.seriesKey);
  });
  return RecurringProjection(
    items,
    _r2(monthly),
    paidTotal: _r2(paidT),
    remainingTotal: _r2(remainT),
    minTotal: _r2(minT),
    maxTotal: _r2(maxT),
  );
}

/// Önümüzdeki [days] gün içinde ödemesi gelen seriler (en yakın önce).
List<RecurringItem> upcomingPaymentsOf(List<RecurringItem> items, DateTime today, {int days = 30}) => [
  for (final i in items)
    if (i.daysUntil(today) >= 0 && i.daysUntil(today) <= days) i,
];

/// Zamanlanacak tek bir yerel hatırlatıcı.
class ReminderPlan {
  const ReminderPlan({required this.id, required this.when, required this.title, required this.body});
  final int id;
  final DateTime when;
  final String title;
  final String body;
}

/// Hatırlatma saati (yerel).
const kReminderHour = 9;

/// Bir sonraki ödeme için "3 gün kala" ve "ödeme günü" hatırlatıcıları; geçmişte kalanlar atlanır, yalnızca
/// hatırlatıcısı açık seriler. Kimlikler seri + eşikten kararlı türetilir (yeniden planlama aynısını yer değiştirir).
List<ReminderPlan> planReminders(List<RecurringItem> items, DateTime now) {
  final out = <ReminderPlan>[];
  for (final i in items) {
    if (!i.remind) continue;
    for (final before in const [3, 0]) {
      final when = DateTime(i.nextDue.year, i.nextDue.month, i.nextDue.day - before, kReminderHour);
      if (!when.isAfter(now)) continue;
      out.add(
        ReminderPlan(
          id: stableId('reminder|${i.profileUid}|${i.seriesKey}|$before'),
          when: when,
          title: before == 0 ? 'Bugün ödeme günü: ${i.title}' : 'Ödeme yaklaşıyor: ${i.title}',
          body: before == 0
              ? '${i.isVariable ? 'Yaklaşık ' : ''}${fmtMoney(i.expected)} tutarındaki ödemenin günü bugün.'
              : '$before gün sonra (${fmtDate(i.nextDue)}) ${i.isVariable ? 'yaklaşık ' : ''}${fmtMoney(i.expected)} ödemen var.',
        ),
      );
    }
  }
  return out;
}
