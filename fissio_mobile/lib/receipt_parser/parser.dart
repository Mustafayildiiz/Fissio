// Go `services/expense/parser.go` çekirdeğinin Dart portu (cihaz içi OCR metnini çevrimdışı ayrıştırır).
//
// Taşınanlar: satır bölme + glif düzeltme, tutar/tarih/işletme, kalem çıkarma (adet satırları dahil),
// indirim ve toplam/kalem uyuşmazlığı bayrağı. TAŞINMAYANLAR: kategori motoru (kategori `Diğer` +
// "kontrol edin"), ondalık ayırıcısı düşmüş tutar kurtarma (recoverBareAmounts) ve ayrıntılı mutabakat
// (reconcile): çevrimdışıyken kalem toplamı fiş toplamıyla tutmazsa yalnızca `needsReview` işaretlenir.
import '../models.dart';
import 'normalize.dart';
import 'summary.dart';

final RegExp amountRe = RegExp(r'(?:\d{1,3}(?:\.\d{3})+|\d+)[.,]\d{2}\b');
final RegExp dateRe = RegExp(r'(?:^|\D)(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})(?:\D|$)');
final RegExp spacedDecimalRe = RegExp(r'(\d[.,])\s(\d{2})\b');
final RegExp qtyPrefixRe = RegExp(
  r'^\s*(\d+(?:[.,]\d{1,3})?)\s*(?:(?:adet|adt|ad|ag|a)\.?\s*[x×*]?|(?:kg|kq|gr|g|lt|l)\.?\s*[x×*]|[x×])\s*((?:\d{1,3}(?:\.\d{3})+|\d+)[.,]\d{2})',
  caseSensitive: false,
);
final RegExp trailingXRe = RegExp(r'\s+x$', caseSensitive: false);
final RegExp bareAmountRe = RegExp(r'[\s*+$x](\d{3,4})\s*$');
final RegExp itemTailRe = RegExp(
  r'(?:[\s*+$]+(?:%\s*\d{1,2}|\d{1,2}\s*%|[48]?08|01|10|18|20|1|8))+[\s*+$]*$',
  caseSensitive: false,
);

const List<String> skipMerchantWords = [
  'elektrik', 'kesildi', 'eku', 'fis', 'tarih', 'saat', 'vkn', 'vergi', 'tel', 'adres', 'mersis',
  'no:', 'www', 'http', 'kasiyer', 'sicil',
];

/// Çevrimdışı ayrıştırıcının sonucu ([ParsedReceipt]'e [toParsedReceipt] ile çevrilir).
class LocalParseResult {
  LocalParseResult({
    required this.merchant,
    required this.amount,
    required this.date,
    required this.items,
    required this.discount,
    required this.needsReview,
    required this.itemsTotal,
  });
  final String merchant;
  final double? amount;
  final String? date; // yyyy-MM-dd
  final List<LocalItem> items;
  final double discount;
  final bool needsReview;
  final double? itemsTotal;

  bool get needsManual => amount == null;

  /// [otherCategoryId]: `Diğer` kategorisinin kimliği (kategori motoru çevrimdışıyken kullanılmaz).
  ParsedReceipt toParsedReceipt({int? otherCategoryId}) => ParsedReceipt(
    merchant: merchant,
    amount: amount,
    date: date == null ? null : DateTime.tryParse(date!),
    categoryId: otherCategoryId ?? 0,
    categoryName: 'Diğer',
    items: [
      for (final i in items)
        ExpenseItem(
          i.name,
          i.amount,
          categoryId: otherCategoryId,
          categoryName: 'Diğer',
          categoryReview: true,
        ),
    ],
    needsManual: needsManual,
    needsReview: needsReview,
    itemsTotal: itemsTotal,
    discountTotal: discount,
    categorySource: 'fallback',
    categoryNeedsReview: true,
  );
}

class LocalItem {
  LocalItem(this.name, this.amount);
  String name;
  double amount;
}

/// Ham OCR metnini ayrıştırır. [now] gelecekteki (>2 gün) tarihleri elemek içindir.
LocalParseResult parseReceiptText(String text, {DateTime? now}) {
  now ??= DateTime.now();
  final lines = splitLines(text);
  final amount = extractAmount(lines);
  final date = extractDate(lines, now);
  final header = lines.length > 8 ? lines.sublist(0, 8) : lines;
  final merchant = extractMerchant(header);
  final discount = extractDiscount(lines);
  final items = extractItems(lines, amount);

  final sum = round2(items.fold<double>(0, (s, i) => s + i.amount));
  bool needsReview = false;
  double? itemsTotal;
  if (items.isNotEmpty) {
    itemsTotal = sum;
    if (amount != null && (round2(sum - discount) - amount).abs() >= 0.01) needsReview = true;
  }
  return LocalParseResult(
    merchant: merchant,
    amount: amount,
    date: date,
    items: items,
    discount: discount,
    needsReview: needsReview,
    itemsTotal: itemsTotal,
  );
}

/// Metni boş olmayan satırlara böler; ondalık boşluklarını ve OCR glif hatalarını (`$` → ş) düzeltir.
List<String> splitLines(String text) {
  final out = <String>[];
  for (final l in text.replaceAll('\r', '').split('\n')) {
    final t = fixTurkishGlyphs(l.replaceAllMapped(spacedDecimalRe, (m) => '${m[1]}${m[2]}')).trim();
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}

/// Tarih parçalarını boşluğa çevirir; "12.05.2024" içindeki "12.05" tutar sanılmasın.
String maskDates(String s) => s.replaceAllMapped(dateRe, (m) => ' ' * m[0]!.length);

List<double> amountsIn(String line) => [
  for (final m in amountRe.allMatches(maskDates(line)))
    ...(() {
      final v = parseAmount(m[0]!);
      return v == null ? <double>[] : [v];
    })(),
];

/// "1.250,50", "125,50", "125.50" biçimlerini normalleştirir.
double? parseAmount(String s) {
  if (s.length < 4) return null;
  final intPart = s.substring(0, s.length - 3).replaceAll('.', '').replaceAll(',', '');
  final v = double.tryParse('$intPart.${s.substring(s.length - 2)}');
  return v == null ? null : round2(v);
}

double? extractAmount(List<String> lines) {
  final tier1 = <int>[], tier2 = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    final f = foldTR(l);
    if (isKDVLine(l) || f.contains('%') || isSubtotalLine(l) || isDiscountLine(l)) continue;
    if (hasKeyword(l, 'toplam', fuzzyMinLen) || hasKeyword(l, 'odenecek', fuzzyMinLen) || hasToken(l, 'top')) {
      tier1.add(i);
    } else if (hasKeyword(l, 'tutar', fuzzyMinLen) ||
        hasKeyword(l, 'tahsil', fuzzyMinLen) ||
        hasKeyword(l, 'kredi kart', fuzzyMinLen) ||
        hasKeyword(l, 'nakit', fuzzyMinLen)) {
      tier2.add(i);
    }
  }
  // Toplam genelde fişin sonuna doğru olduğu için sondan başla.
  for (final tier in [tier1, tier2]) {
    for (var k = tier.length - 1; k >= 0; k--) {
      final i = tier[k];
      final a = amountsIn(lines[i]);
      if (a.isNotEmpty) return a.last;
      // OCR etiketi ve tutarı ayrı satırlara bölmüş olabilir.
      if (i + 1 < lines.length) {
        final b = amountsIn(lines[i + 1]);
        if (b.isNotEmpty) return b.last;
      }
    }
  }
  // Son çare: KDV/yüzde satırları dışındaki en büyük tutar.
  double? best;
  for (final l in lines) {
    if (isKDVLine(l) || foldTR(l).contains('%')) continue;
    for (final a in amountsIn(l)) {
      if (best == null || a > best) best = a;
    }
  }
  return best;
}

String? extractDate(List<String> lines, DateTime now) {
  final limit = DateTime.utc(now.year, now.month, now.day).add(const Duration(days: 2));
  for (final l in lines) {
    for (final m in dateRe.allMatches(l)) {
      final d = int.parse(m[1]!), mo = int.parse(m[2]!);
      var y = int.parse(m[3]!);
      if (m[3]!.length == 2) y += 2000;
      final t = DateTime.utc(y, mo, d);
      // DateTime taşan günleri kaydırır (31.02 gibi); geçersizleri ele.
      if (t.day != d || t.month != mo || y < 2000 || t.isAfter(limit)) continue;
      return '${y.toString().padLeft(4, '0')}-${mo.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
    }
  }
  return null;
}

String extractMerchant(List<String> header) {
  for (final l in header) {
    final f = foldTR(l);
    if (skipMerchantWords.any(f.contains)) continue;
    if (isStarBanner(l)) continue; // "** ELEKTRIK KESILDI **" bilgi satırı işletme adı değildir
    final cs = [for (final r in l.runes) String.fromCharCode(r)];
    final letters = cs.where(isLetterCh).length;
    final digits = cs.where(isDigitCh).length;
    if (letters >= 3 && digits <= letters) return cleanMerchant(l);
  }
  return '';
}

String cleanMerchant(String l) {
  l = dropLeadingJunk(trimChars(l, '*-=_# ').trim());
  final r = l.runes.toList();
  return r.length > 60 ? String.fromCharCodes(r.sublist(0, 60)) : l;
}

bool _approxEq(double a, double b) => (a - b).abs() < 0.005;

/// Net satır tutarı taşıyan adet satırını ("2 ADET X 15,00 = 30,00") işler. Net tutar satırın EN SAĞINDAKİ
/// tutardır; birim fiyat asla ayrı kalem olmaz.
void _applyQtyLine(List<LocalItem> items, String pending, double qty, double unit, double net) {
  if (pending.isNotEmpty) {
    items.add(LocalItem(pending, net));
  } else if (items.isEmpty) {
    return;
  } else if (_approxEq(items.last.amount, net)) {
    return;
  } else if (qty > 1 && _approxEq(items.last.amount, unit) && _approxEq(round2(qty * unit), net)) {
    items.last.amount = net;
  }
}

/// lines[i] adlı ve tutarı net olan bir kalem satırı mı (BIM: adet satırı kalemin üstünde)?
bool _nextLineIsItemOf(List<String> lines, int i, double net) {
  if (i >= lines.length || isTotalLabel(lines[i])) return false;
  final lab = nonItemLabel(lines[i]);
  if (lab.strong || lab.weak) return false;
  final m = amountRe.allMatches(maskDates(lines[i])).toList();
  if (m.isEmpty) return false;
  final last = m.last;
  final v = parseAmount(lines[i].substring(last.start, last.end));
  return v != null && _approxEq(v, net) && countLetters(cleanItemName(lines[i].substring(0, last.start))) >= 2;
}

List<LocalItem> extractItems(List<String> lines, double? totalAmount) {
  final items = <LocalItem>[];
  var pendingName = ''; // üstteki satır yalnızca ürün adı (alttaki adet satırının kalemi olabilir)
  for (var li = 0; li < lines.length; li++) {
    var l = lines[li];
    if (isTotalLabel(l)) break; // Toplam satırından sonrası ödeme/alt bilgi
    final pending = pendingName;
    pendingName = '';
    final q = qtyPrefixRe.firstMatch(l);
    if (q != null) {
      final qty = double.tryParse(q[1]!.replaceAll(',', '.')) ?? 0;
      final unit = parseAmount(q[2]!) ?? 0;
      final rest = l.substring(q.end).trim();
      final m = amountRe.allMatches(maskDates(rest)).toList();
      if (m.isNotEmpty && countLetters(cleanItemName(rest.substring(0, m.last.start))) < 2) {
        final net = parseAmount(rest.substring(m.last.start, m.last.end)) ?? 0;
        _applyQtyLine(items, pending, qty, unit, net);
        continue;
      }
      if (rest.isEmpty && pending.isNotEmpty && qty > 0 && !_nextLineIsItemOf(lines, li + 1, round2(qty * unit))) {
        // "CAY" + "2 ADET X 15,00": net yazılmamış → miktar x birim.
        items.add(LocalItem(pending, round2(qty * unit)));
        continue;
      }
      l = rest; // adet satırı kalem değildir; kalan işlenir
    }
    final lab = nonItemLabel(l);
    if (lab.strong || lab.weak) continue;
    final masked = maskDates(l);
    final matches = amountRe.allMatches(masked).toList();
    if (matches.isEmpty) {
      final b = bareAmountRe.firstMatch(l);
      if (b != null) continue; // ondalığı düşmüş tutar: çevrimdışıyken kurtarılmaz
      final name = cleanItemName(l);
      if (countLetters(name) >= 3 && !isStarBanner(l)) pendingName = name;
      continue;
    }
    final lastMatch = matches.last;
    final val = parseAmount(masked.substring(lastMatch.start, lastMatch.end));
    if (val == null || val <= 0) continue;
    if (totalAmount != null && (val - totalAmount).abs() < 0.005 && lines.length <= 3) continue;
    var namePart = cleanItemName(l.substring(0, lastMatch.start).trim());
    if (countLetters(namePart) >= 2) {
      final r = namePart.runes.toList();
      if (r.length > 80) namePart = String.fromCharCodes(r.sublist(0, 80));
      items.add(LocalItem(namePart, val));
    }
  }
  return items;
}

/// Kalem adındaki KDV oranı ve sütun kalıntılarını temizler ("...  %08 *" → ad).
String cleanItemName(String s) {
  s = trimRightChars(s.trim(), ' *+\$');
  s = s.replaceFirst(trailingXRe, '');
  s = s.replaceFirst(itemTailRe, '');
  return trimChars(s.trim(), '*-=_#:+\$ ');
}
