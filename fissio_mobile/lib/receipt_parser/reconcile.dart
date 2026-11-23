// Go `services/expense/reconcile.go` portu: toplam çözümleme (resolveTotal), ondalığı düşmüş tutar
// kurtarma (recoverBareAmounts) ve kalem/toplam mutabakatı (reconcile). Eşikler ve sıralar birebir aynı
// tutulur; ortak vektörler `testdata/parse/*.json` (Go `golden_parse_test.go`, Dart `golden_parse_test.dart`).
import 'normalize.dart';
import 'parser.dart' show LocalItem, amountsIn;
import 'summary.dart';

bool approxEq(double a, double b) => (a - b).abs() < 0.005;

double sumItems(List<LocalItem> items) => round2(items.fold<double>(0, (s, i) => s + i.amount));

/// İki kalemin aynı ürünün çift okunması olup olmadığı: aynı fiyat ve aynı/benzer ad.
bool sameItem(LocalItem a, LocalItem b) {
  if ((a.amount - b.amount).abs() >= 0.005) return false;
  final na = foldTR(a.name), nb = foldTR(b.name);
  if (na == nb) return true;
  var limit = na.runes.length ~/ 5;
  if (limit < 1) limit = 1;
  return levenshtein(na, nb) <= limit;
}

const String recOK = 'ok';
const String recDiscount = 'discount_applied';
const String recDuplicate = 'duplicate_removed';
const String recMismatch = 'mismatch';

/// Kalemler toplamı ile fiş toplamının mutabakat sonucu (Go `Reconciliation`).
class LocalReconciliation {
  const LocalReconciliation(this.status, {this.diff = 0, this.suspectIndex, this.reason = ''});

  /// ok | discount_applied | duplicate_removed | mismatch
  final String status;

  /// (kalemler − indirim) − fiş toplamı, düzeltmelerden SONRA (0 = tutarlı).
  final double diff;

  /// Farkı tek başına açıklayan (ama kanıt olmadığı için silinmeyen) kalem.
  final int? suspectIndex;
  final String reason;
}

class ReconcileOutcome {
  ReconcileOutcome(this.items, this.discount);
  List<LocalItem> items;
  bool needsReview = false;
  double? itemsTotal;

  /// Kalemlerden düşülecek indirim (0 = yok / kalemlere zaten yansımış).
  double discount;
  LocalReconciliation? info;
}

/// Kalem fiyatları toplamını (indirim düşülerek) fiş toplamıyla karşılaştırır:
///   - Fark yoksa bayrak yok; indirim kalemlere zaten yansımışsa indirim 0'lanır.
///   - Kalemler fazla ve fark TEK bir kalemin fiyatına eşitse yalnızca çift okuma kanıtı varsa silinir.
///   - Kalemler eksikse fark atlanan etiketli satıra / tek kaleme eşitse gerekçe raporlanır.
///   - Fark kapanmazsa needsReview ve hesaplanan kalem toplamı döner.
ReconcileOutcome reconcile(List<LocalItem> items, double? total, double discount, List<LocalItem> skipped) {
  final o = ReconcileOutcome(items, discount);
  if (total == null || items.isEmpty) return o;
  final sum = sumItems(items);
  if (discount > 0 && approxEq(sum, total)) {
    // İndirim satırları kalem tutarlarına zaten yansıtılmış (kalemler net yazılmış).
    o.discount = 0;
    o.info = const LocalReconciliation(recOK, reason: 'discount_already_in_items');
    return o;
  }
  final diff = round2(sum - discount - total);
  if (approxEq(diff, 0)) {
    o.info = LocalReconciliation(discount > 0 ? recDiscount : recOK);
    return o;
  }
  int? suspect;
  var reason = '';
  if (diff > 0) {
    final d = duplicateToRemove(items, diff);
    if (d >= 0) {
      final removed = items[d].name;
      o.items = [...items.sublist(0, d), ...items.sublist(d + 1)];
      o.info = LocalReconciliation(recDuplicate, reason: 'removed_duplicate: $removed');
      return o;
    }
    final i = uniqueAmountIndex(items, diff);
    if (i >= 0) {
      suspect = i;
      reason = 'excess_equals_item';
    }
  } else {
    final missing = -diff;
    for (final s in skipped) {
      if (approxEq(s.amount, missing)) {
        reason = 'missing_equals_skipped_line: ${s.name}';
        break;
      }
    }
    if (reason.isEmpty) {
      final i = uniqueAmountIndex(items, missing);
      if (i >= 0) {
        suspect = i;
        reason = 'missing_equals_item';
      }
    }
  }
  o
    ..needsReview = true
    ..itemsTotal = sum
    ..info = LocalReconciliation(recMismatch, diff: diff, suspectIndex: suspect, reason: reason);
  return o;
}

/// Fiyatı diff'e eşit ve çift okuma kanıtı olan kalemin indeksi (-1: yok).
int duplicateToRemove(List<LocalItem> items, double diff) {
  for (var i = 0; i < items.length; i++) {
    if (!approxEq(items[i].amount, diff)) continue;
    if (i > 0 && sameItem(items[i], items[i - 1])) return i;
    if (nonItemLabel(items[i].name).strong) return i; // özet satırı kalem olarak sızmış
  }
  return -1;
}

/// Fiyatı v olan TEK kalemin indeksi (yoksa ya da birden fazlaysa -1).
int uniqueAmountIndex(List<LocalItem> items, double v) {
  var found = -1;
  for (var i = 0; i < items.length; i++) {
    if (approxEq(items[i].amount, v)) {
      if (found >= 0) return -1;
      found = i;
    }
  }
  return found;
}

/// Fişin alt bloğundaki tutarlardan tutarlı bir toplam bulur (etiket/tutar sütunları kaymış olsa bile):
///   - kalemlerin (indirim düşülmüş) toplamı alt blokta bir tutara eşitse o tutar;
///   - nakit ödemede ödenen − para üstü = toplam (225,00 − 1,35 = 223,65).
/// Mevcut toplam zaten tutarlıysa null. Yalnızca toplam/KDV etiketli ilk satırdan itibaren olan blok
/// kullanılır; ARA TOPLAM ve İNDİRİM satırlarının tutarları havuza girmez.
/// Kalem tutarları KDV'siz yazılmış faturaları (e-fatura / e-arşiv) tanıyıp uyuşmazlık saymaz (Go `vatExcludedItems`):
/// toplam kesin "ödenecek / vergiler dahil / genel toplam" etiketli ve (toplam − kalemler) farkı bir KDV satırının (ya da
/// KDV satırları toplamının) tutarına eşit. Etiket şart: yalnız tesadüfen KDV'ye eşit fark yeterli değildir.
bool vatExcludedItems(List<String> lines, List<LocalItem> items, double discount, double total) {
  if (!_labeledGrandTotal(lines, total)) return false;
  final missing = round2(total - (sumItems(items) - discount));
  if (missing <= 0.005) return false;
  final each = <double>[];
  var sum = 0.0;
  for (final l in lines) {
    if (!isKDVLine(l)) continue;
    final a = amountsIn(l);
    if (a.isEmpty) continue;
    each.add(a.last);
    if (!hasPhrase(l, 'topkdv') && !hasKeyword(l, 'toplam', fuzzyMinLen)) sum += a.last;
  }
  each.add(round2(sum));
  return each.any((v) => v > 0 && approxEq(v, missing));
}

bool _labeledGrandTotal(List<String> lines, double v) {
  for (final l in lines) {
    if (!(hasKeyword(l, 'odenecek', fuzzyMinLen) || hasPhrase(l, 'vergilerdahil') || hasPhrase(l, 'geneltoplam'))) continue;
    if (amountsIn(l).any((a) => (a - v).abs() < 0.005)) return true;
  }
  return false;
}

double? resolveTotal(List<String> lines, List<LocalItem> items, double discount, double? current) {
  // Açıkça "ÖDENECEK TUTAR / VERGİLER DAHİL TOPLAM / GENEL TOPLAM" etiketli satırdaki tutar kesin toplamdır (e-fatura:
  // kalem toplamı KDV'siz ara toplamdır ve alt blokta geçer; toplam olarak ezilmemeli).
  if (current != null && _labeledGrandTotal(lines, current)) return null;
  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (isTotalLabel(l) || isKDVLine(l) || foldTR(l).contains('topk')) {
      start = i;
      break;
    }
  }
  if (start < 0) return null;
  final pool = <double>[];
  for (final l in lines.sublist(start)) {
    if (isSubtotalLine(l) || isDiscountLine(l)) continue;
    pool.addAll(amountsIn(l));
  }
  bool has(double v) => pool.any((a) => (a - v).abs() < 0.005);
  bool same(double v) => current != null && (current - v).abs() < 0.005;

  // 1) Kalem toplamı alt blokta bir tutara eşit
  if (items.length >= 2) {
    final sum = round2(sumItems(items) - discount);
    if (has(sum) && !same(sum)) return sum;
  }
  // 2) ödenen − para üstü = toplam
  double? best;
  for (final paid in pool) {
    for (final change in pool) {
      final total = round2(paid - change);
      if (change <= 0 || total <= change || !has(total) || (total - paid).abs() < 0.005) continue;
      if (same(total)) return null; // mevcut toplam zaten tutarlı
      if (best == null || total > best) best = total;
    }
  }
  return best;
}

/// Ondalık ayırıcısı düşmüş tutarlı satır ("*070" → 0,70). [pos]: aday çıktığında toplanmış kalem sayısı.
class BareCandidate {
  BareCandidate(this.pos, this.item);
  final int pos;
  final LocalItem item;
}

/// Kalem toplamı fiş toplamının altındaysa ve eksik fark TAM OLARAK bir aday alt kümesinin toplamına
/// eşitse (en fazla 8 aday) o kalemleri yerlerine ekler; fark kapanmıyorsa hiçbir şey eklenmez.
List<LocalItem> recoverBareAmounts(List<LocalItem> items, List<BareCandidate> cands, double? total, double discount) {
  if (total == null || cands.isEmpty || cands.length > 8) return items;
  final diff = round2(total + discount - sumItems(items));
  if (diff <= 0.005) return items;
  final picked = <int>[];
  for (var mask = 1; mask < 1 << cands.length; mask++) {
    var sum = 0.0;
    for (var i = 0; i < cands.length; i++) {
      if (mask & (1 << i) != 0) sum += cands[i].item.amount;
    }
    if ((round2(sum) - diff).abs() < 0.005) {
      for (var i = 0; i < cands.length; i++) {
        if (mask & (1 << i) != 0) picked.add(i);
      }
      break;
    }
  }
  if (picked.isEmpty) return items;
  final out = <LocalItem>[];
  var pi = 0;
  for (var idx = 0; idx <= items.length; idx++) {
    while (pi < picked.length && cands[picked[pi]].pos == idx) {
      out.add(cands[picked[pi]].item);
      pi++;
    }
    if (idx < items.length) out.add(items[idx]);
  }
  return out;
}
