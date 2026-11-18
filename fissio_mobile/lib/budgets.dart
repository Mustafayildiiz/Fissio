import 'models.dart';
import 'theme.dart' show fmtMoney;

/// Kategori bazlı aylık bütçe hesabı (saf fonksiyonlar; arayüz ve bildirimler buradan beslenir).
///
/// Harcama, Özet ekranındaki kategori dağılımıyla aynı şekilde FİŞ tutarı ([Expense.amount]) üzerinden ve
/// fişin kendi kategorisine ([Expense.categoryId]) göre, yalnızca bütçenin profilinde ve takvim ayında toplanır.

/// Limitin %80'i: uyarı (sarı).
const kBudgetWarnPercent = 80;

/// Limitin %100'ü: kritik (kırmızı).
const kBudgetExceededPercent = 100;

enum BudgetLevel { ok, warning, exceeded }

/// Harcama/limit oranını eşiklere göre sınıflar. Karşılaştırma kuruş (tamsayı) üzerinden yapılır:
/// 79,99% → ok, 80% → warning, 100% → exceeded (kayan nokta hatası sınır değerleri kaydırmasın).
BudgetLevel budgetLevel(double spent, double limit) {
  if (limit <= 0) return BudgetLevel.ok;
  final s = (spent * 100).round();
  final l = (limit * 100).round();
  if (s * 100 >= l * kBudgetExceededPercent) return BudgetLevel.exceeded;
  if (s * 100 >= l * kBudgetWarnPercent) return BudgetLevel.warning;
  return BudgetLevel.ok;
}

class BudgetProgress {
  const BudgetProgress({required this.budget, required this.spent});
  final Budget budget;
  final double spent;

  /// Harcama / limit (1'i aşabilir).
  double get ratio => budget.limit <= 0 ? 0 : spent / budget.limit;
  BudgetLevel get level => budgetLevel(spent, budget.limit);
  double get remaining => budget.limit - spent;
}

bool _sameMonth(DateTime a, DateTime b) => a.year == b.year && a.month == b.month;

/// [profileUid] profilinin [now] ayındaki toplam harcaması (tüm kategoriler); widget ve "Bu ay" toplamı.
double monthTotalFor(List<Expense> expenses, String? profileUid, DateTime now) {
  var t = 0.0;
  for (final e in expenses) {
    if ((profileUid == null || e.profileUid == profileUid) && _sameMonth(e.date, now)) t += e.amount;
  }
  return (t * 100).round() / 100;
}

/// Bir profilin bütçe satırları ve içinde bulunulan aydaki harcamaları. Toplam aylık bütçe ([Budget.isTotal])
/// varsa İLK sırada gelir ve tüm kategorilerin o ayki toplamını sayar; kategori limitleri ada göre sıralıdır.
List<BudgetProgress> computeBudgetProgress(
  List<Expense> expenses,
  List<Budget> budgets,
  String profileUid,
  DateTime now,
) {
  final spent = <int, double>{};
  var all = 0.0;
  for (final e in expenses) {
    if (e.profileUid != profileUid || !_sameMonth(e.date, now)) continue;
    spent[e.categoryId] = (spent[e.categoryId] ?? 0) + e.amount;
    all += e.amount;
  }
  double cents(double v) => (v * 100).round() / 100;
  final out = [
    for (final b in budgets)
      if (b.profileUid == profileUid)
        BudgetProgress(budget: b, spent: cents(b.isTotal ? all : (spent[b.categoryId] ?? 0))),
  ]..sort((a, b) {
      if (a.budget.isTotal != b.budget.isTotal) return a.budget.isTotal ? -1 : 1;
      return a.budget.categoryName.compareTo(b.budget.categoryName);
    });
  return out;
}

/// Gönderilecek tek bir bütçe bildirimi.
class BudgetAlert {
  const BudgetAlert({required this.progress, required this.threshold});
  final BudgetProgress progress;

  /// 80 ya da 100.
  final int threshold;

  String get title {
    final total = progress.budget.isTotal;
    if (threshold >= kBudgetExceededPercent) {
      return total ? 'Aylık toplam bütçe aşıldı' : '${progress.budget.categoryName} bütçesi aşıldı';
    }
    return total
        ? 'Aylık toplam bütçenin %$kBudgetWarnPercent\'ine ulaştın'
        : '${progress.budget.categoryName} bütçesinin %$kBudgetWarnPercent\'ine ulaştın';
  }

  String get body =>
      'Bu ay ${fmtMoney(progress.spent)} harcadın; limit ${fmtMoney(progress.budget.limit)}.';
}

class BudgetAlertResult {
  const BudgetAlertResult(this.alerts, this.sent);
  final List<BudgetAlert> alerts;

  /// Güncel "gönderildi" kümesi (yalnızca içinde bulunulan ayın anahtarları kalır).
  final Set<String> sent;
}

String _ym(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// "Bu ay, bu profil, bu kategori, bu eşik" için gönderildi anahtarı.
String budgetAlertKey(DateTime now, String profileUid, int categoryId, int threshold) =>
    '${_ym(now)}|$profileUid|$categoryId|$threshold';

/// Eşik kontrolü: her bütçe için ulaşılan en yüksek eşik (%80 / %100) o ay ilk kez aşılıyorsa bildirim üretir.
/// - Aynı ay + aynı eşik için tekrar bildirim yok ([sent] kümesi).
/// - Tek fiş hem %80'i hem %100'ü geçtiyse yalnızca %100 bildirimi gider, iki eşik de "gönderildi" işaretlenir.
/// - Önceki aylara ait anahtarlar temizlenir.
BudgetAlertResult evaluateBudgetAlerts(List<BudgetProgress> progress, Set<String> sent, DateTime now) {
  final month = _ym(now);
  final next = {for (final k in sent) if (k.startsWith('$month|')) k};
  final alerts = <BudgetAlert>[];
  for (final p in progress) {
    final level = p.level;
    if (level == BudgetLevel.ok) continue;
    final threshold = level == BudgetLevel.exceeded ? kBudgetExceededPercent : kBudgetWarnPercent;
    final b = p.budget;
    final key = budgetAlertKey(now, b.profileUid, b.categoryId, threshold);
    if (next.contains(key)) continue;
    alerts.add(BudgetAlert(progress: p, threshold: threshold));
    next.add(key);
    if (threshold == kBudgetExceededPercent) {
      next.add(budgetAlertKey(now, b.profileUid, b.categoryId, kBudgetWarnPercent));
    }
  }
  return BudgetAlertResult(alerts, next);
}

/// Bildirim kimliği (aynı bütçe+eşik yeni bildirimle yer değiştirir).
int budgetNotificationId(String profileUid, int categoryId, int threshold) =>
    stableId('budget|$profileUid|$categoryId|$threshold');

/// Dart `hashCode` süreçler arasında kararlı olmadığı için FNV-1a (31 bit).
int stableId(String s) {
  var h = 0x811c9dc5;
  for (final u in s.codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0x7fffffff;
  }
  return h;
}

/// "8.000", "8000,50", "8000.50" gibi girdilerden tutar okur; geçersizse null.
double? parseMoneyInput(String input) {
  var s = input.replaceAll(RegExp(r'[\s₺]|TL', caseSensitive: false), '');
  if (s.isEmpty) return null;
  if (s.contains(',')) {
    s = s.replaceAll('.', '').replaceAll(',', '.');
  } else if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s)) {
    s = s.replaceAll('.', '');
  }
  final v = double.tryParse(s);
  return v == null || v.isNaN || v.isInfinite ? null : v;
}
