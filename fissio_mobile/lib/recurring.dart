import 'budgets.dart' show stableId;
import 'models.dart';
import 'receipt_parser/normalize.dart' show foldTR;
import 'theme.dart' show fmtDate, fmtMoney;

/// Tekrarlayan giderler ("Her ay tekrarlanır"): seri, projeksiyon, yaklaşan ödemeler ve hatırlatıcı planı.
/// Sunucudaki `recurring.go` ile aynı kurallar (offline/yerel fişler de dahil olsun diye istemcide de hesaplanır):
///
/// Çift sayım önlemi: aynı gider her ay yeni fiş olarak girilir (Ocak ve Şubat elektrik faturası). Projeksiyon fiş
/// başına değil SERİ başınadır. Seri anahtarı = kategori + normalize işletme adı (profil başına). Serinin güncel
/// hali o anahtardaki EN SON fiştir (tarih, sonra id). En son fiş işaretliyse seri aktiftir ve tutarı / ödeme
/// günü o fişten gelir; işaretsizse seri bitmiş sayılır (kullanıcı işareti kaldırdı).

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
  });
  final String seriesKey;
  final String profileUid;
  final String merchant;
  final int categoryId;
  final String categoryName;
  final double amount;
  final int day;
  final bool remind;
  final int lastExpenseId;
  final DateTime lastDate;
  final DateTime nextDue;

  String get title => merchant.isEmpty ? categoryName : merchant;

  /// Bugünden [nextDue]'ya kalan gün (0 = bugün).
  int daysUntil(DateTime today) => _day(nextDue).difference(_day(today)).inDays;
}

class RecurringProjection {
  const RecurringProjection(this.items, this.monthlyTotal);
  final List<RecurringItem> items;

  /// "Aylık Sabit Gider Projeksiyonu": aktif serilerin güncel tutarları toplamı.
  final double monthlyTotal;
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

RecurringProjection buildRecurring(List<Expense> expenses, DateTime today) {
  final latest = <String, Expense>{};
  for (final e in expenses) {
    final k = '${e.profileUid}#${recurringSeriesKey(e.merchant, e.categoryId)}';
    final cur = latest[k];
    if (cur == null) {
      latest[k] = e;
      continue;
    }
    final c = _day(e.date).compareTo(_day(cur.date));
    if (c > 0 || (c == 0 && e.id > cur.id)) latest[k] = e;
  }
  final items = <RecurringItem>[];
  var total = 0.0;
  for (final e in latest.values) {
    if (!e.isRecurring) continue;
    items.add(
      RecurringItem(
        seriesKey: recurringSeriesKey(e.merchant, e.categoryId),
        profileUid: e.profileUid,
        merchant: e.merchant,
        categoryId: e.categoryId,
        categoryName: e.categoryName,
        amount: e.amount,
        day: e.recurringDay,
        remind: e.recurringRemind,
        lastExpenseId: e.id,
        lastDate: e.date,
        nextDue: nextDueDate(e.recurringDay, e.date, today),
      ),
    );
    total += e.amount;
  }
  items.sort((a, b) {
    final c = a.nextDue.compareTo(b.nextDue);
    return c != 0 ? c : a.seriesKey.compareTo(b.seriesKey);
  });
  return RecurringProjection(items, (total * 100).round() / 100);
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
              ? '${fmtMoney(i.amount)} tutarındaki ödemenin günü bugün.'
              : '$before gün sonra (${fmtDate(i.nextDue)}) ${fmtMoney(i.amount)} ödemen var.',
        ),
      );
    }
  }
  return out;
}
