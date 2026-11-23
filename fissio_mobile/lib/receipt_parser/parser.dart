// Go `services/expense/parser.go` çekirdeğinin Dart portu (cihaz içi OCR metnini çevrimdışı ayrıştırır).
//
// Para sonuçları Go ile birebir aynıdır (ortak vektörler: `testdata/parse/*.json`): satır bölme + glif
// düzeltme, tutar/tarih, işletme (bilinen marka içeren başlık satırı önce, `brands.dart`), kalem çıkarma
// (adet satırları dahil), indirim, resolveTotal, recoverBareAmounts ve reconcile (`reconcile.dart`).
// TAŞINMAYAN: kategori motoru (kategori `Diğer` + "kontrol edin") ve sunucuda kullanıcının kategorilere
// eklediği ek marka `keywords`'leri.
import '../models.dart';
import 'brands.dart';
import 'cancel.dart';
import 'normalize.dart';
import 'reconcile.dart';
import 'summary.dart';

export 'brands.dart' show merchantBrands;
export 'reconcile.dart' show LocalReconciliation;

final RegExp amountRe = RegExp(r'(?:\d{1,3}(?:\.\d{3})+|\d+)[.,]\d{2}\b');
// Saat tarihe boşluksuz yapışık olabilir ("18/10/202617:06"): yılın ardından SS:DD de kabul edilir.
final RegExp dateRe = RegExp(r'(?:^|\D)(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})(?:\D|$|\d{2}:\d{2})');
// Tutara yapışık para birimi: "5.00t" (TL simgesi OCR'da t), "24,90TL", "5,00₺" → "5.00" / "24,90".
final RegExp currencySuffixRe = RegExp(r'(\d[.,]\d{2})(?:TL|tl|[tT₺])\b');
// Satır SONUNDA ondalıksız tutar + açık para birimi: "355TRY", "665 TRY", "-310 TRY", "1.250 TL" → "355,00" … (dijital
// fiş/e-posta tabloları; Go `intCurrencyRe` ikizi). Satır sonu şartı "10 TL indirim kuponu" gibi açıklamaları bozmaz.
// Grup 1 = önceki karakter (rakam/nokta/virgül OLAMAZ), grup 2 = tutar.
final RegExp intCurrencyRe = RegExp(r'(^|[^\d.,])(-?(?:\d{1,3}(?:\.\d{3})+|\d+))\s?(?:TRY|TL|₺)\s*$', caseSensitive: false);
// Ürün satırı izi: KDV oranı sütunu (%08, x08) ya da satır sonunda tutar; başlık/işletme adı olamaz.
final RegExp itemRowRe = RegExp(r'%\s*\d{1,2}|(?:^|\s)[xX]\d{2}\b|\d[.,]\d{2}\s*[*tT₺]?\s*$');
final RegExp spacedDecimalRe = RegExp(r'(\d[.,])\s(\d{2})\b');
// Sol kenarı kırpılmış fişlerde miktar rakamı düşebilir ("ADET X 13,50 TL"): sayı yalnız "adet/adt + x"
// biçiminde isteğe bağlıdır (grup 1 boş kalır, miktar bilinmez).
final RegExp qtyPrefixRe = RegExp(
  r'^\s*(?:(\d+(?:[.,]\d{1,3})?)\s*(?:(?:adet|adt|ad|ag|a)\.?\s*[x×*]?|(?:kg|kq|k9|gr|g|lt|l)\.?\s*[x×*]|[x×])|(?:adet|adt)\.?\s*[x×*])\s*((?:\d{1,3}(?:\.\d{3})+|\d+)[.,]\d{2})',
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
    this.reconciliation,
  });
  final String merchant;
  final double? amount;
  final String? date; // yyyy-MM-dd
  final List<LocalItem> items;

  /// Kalem toplamından düşülecek indirim (Go `discount_total`): indirim yoksa ya da kalem fiyatlarına
  /// zaten yansımışsa 0. Kaydedilen tutar `kalemler − discount`.
  final double discount;

  /// Kalem toplamı (indirim düşülerek) fiş toplamıyla tutmuyor.
  final bool needsReview;

  /// Yalnızca uyuşmazlıkta: hesaplanan kalem toplamı (Go `items_total`).
  final double? itemsTotal;
  final LocalReconciliation? reconciliation;

  bool get needsManual => amount == null;

  /// [otherCategoryId]: `Diğer` kategorisinin kimliği (kategori motoru çevrimdışıyken kullanılmaz).
  ParsedReceipt toParsedReceipt({int? otherCategoryId}) => ParsedReceipt(
    merchant: merchant,
    amount: amount,
    date: date == null ? null : DateTime.tryParse(date!),
    categoryId: otherCategoryId ?? 0,
    categoryName: kOtherCategory,
    items: [
      for (final i in items)
        ExpenseItem(
          i.name,
          i.amount,
          categoryId: otherCategoryId,
          categoryName: kOtherCategory,
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
  var amount = extractAmount(lines);
  final date = extractDate(lines, now);
  final header = lines.length > 8 ? lines.sublist(0, 8) : lines;
  final merchant = extractMerchant(header);
  final discount = extractDiscount(lines);

  final ex = extractItemsWithBare(lines, amount);
  final resolved = resolveTotal(lines, ex.items, discount, amount);
  if (resolved != null) amount = resolved;
  final items = recoverBareAmounts(ex.items, ex.bare, amount, discount);
  final o = reconcile(items, amount, discount, ex.skipped);
  if (o.needsReview && amount != null && vatExcludedItems(lines, o.items, o.discount, amount)) {
    // E-fatura: kalem tutarları KDV'siz; toplam = kalemler + KDV ve "Ödenecek Tutar" etiketli. Uyuşmazlık değil.
    o.needsReview = false;
    o.itemsTotal = null;
    o.info = const LocalReconciliation(recOK, reason: 'items_exclude_vat');
  }
  return LocalParseResult(
    merchant: merchant,
    amount: amount,
    date: date,
    items: o.items,
    discount: o.discount,
    needsReview: o.needsReview,
    itemsTotal: o.itemsTotal,
    reconciliation: o.info,
  );
}

/// Metni boş olmayan satırlara böler; ondalık boşluklarını ve OCR glif hatalarını (`$` → ş) düzeltir.
List<String> splitLines(String text) {
  final out = <String>[];
  for (final l in text.replaceAll('\r', '').split('\n')) {
    final t = fixTurkishGlyphs(
      l
          .replaceAllMapped(spacedDecimalRe, (m) => '${m[1]}${m[2]}')
          .replaceAllMapped(currencySuffixRe, (m) => m[1]!)
          .replaceAllMapped(intCurrencyRe, (m) => '${m[1]}${m[2]},00'),
    ).trim();
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
      // Uygulama fişlerinde (Toplam:) tutar etiketin üstüne yerleşebilir: yalnızca tutardan oluşan önceki satır
      // da etiketin değeridir.
      if (i > 0 && isAmountOnlyLine(lines[i - 1])) {
        final c = amountsIn(lines[i - 1]);
        if (c.length == 1) return c.first;
      }
      // Sütunlar yer değiştirmiş: KDV satırı hem KDV'yi hem toplamı taşır ("TOPKDV 307.85 22,79" + boş "TOPLAM").
      // KDV toplamdan çok küçüktür (en fazla ~%20): büyük tutar toplamdır.
      if (i > 0 && isKDVLine(lines[i - 1])) {
        final d = amountsIn(lines[i - 1]);
        if (d.length == 2) {
          final hi = d[0] > d[1] ? d[0] : d[1], lo = d[0] > d[1] ? d[1] : d[0];
          if (lo > 0 && hi >= lo * 5) return hi;
        }
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

/// Satırın yalnızca bir tutardan (ve "*", "TL" gibi sütun işaretlerinden) oluştuğunu söyler.
bool isAmountOnlyLine(String l) {
  final m = amountRe.allMatches(l).toList();
  if (m.length != 1) return false;
  final rest = l.substring(0, m.first.start) + l.substring(m.first.end);
  return trimChars(rest, ' *+\$=:-').isEmpty;
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
  // Bilinen bir marka içeren ilk satır en güvenilir adaydır (Go: atlama/yıldız/harf filtreleri yok).
  for (final l in header) {
    if (itemRowRe.hasMatch(l)) continue; // ürün satırı ("KASAR PEYNIR %01 *139,90") marka eşleşmesinden de dışlanır
    final f = foldTR(l);
    if (merchantBrands.any((kw) => containsWordFuzzy(f, kw))) return cleanMerchant(l);
  }
  for (final l in header) {
    final f = foldTR(l);
    if (skipMerchantWords.any(f.contains)) continue;
    if (isStarBanner(l)) continue; // "** ELEKTRIK KESILDI **" bilgi satırı işletme adı değildir
    if (itemRowRe.hasMatch(l)) break; // başlık bitti (kırpılmış fişte ilk ürün satırı): sonrası işletme adı olamaz
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

/// Net satır tutarı taşıyan adet satırını ("2 ADET X 15,00 = 30,00") işler. Net tutar satırın EN SAĞINDAKİ
/// tutardır; birim fiyat asla ayrı kalem olmaz.
void _applyQtyLine(List<LocalItem> items, String pending, double qty, double unit, double net) {
  if (pending.isNotEmpty) {
    items.add(LocalItem(pending, net));
  } else if (items.isEmpty) {
    return;
  } else if (approxEq(items.last.amount, net)) {
    return;
  } else if (qty > 1 && approxEq(items.last.amount, unit) && approxEq(round2(qty * unit), net)) {
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
  return v != null && approxEq(v, net) && countLetters(cleanItemName(lines[i].substring(0, last.start))) >= 2;
}

List<LocalItem> extractItems(List<String> lines, double? totalAmount) => extractItemsWithBare(lines, totalAmount).items;

/// Kalemleri çıkarır. Ayrıca ondalık ayırıcısı OCR'da düşmüş ("*070", "100") satırları ADAY olarak
/// ([bare]; yalnızca toplamla doğrulanınca eklenir, recoverBareAmounts) ve yalnızca kısa bir etiket
/// kelimesi yüzünden atlanan tutarlı satırları ([skipped]; mutabakat gerekçesi) döndürür.
({List<LocalItem> items, List<BareCandidate> bare, List<LocalItem> skipped}) extractItemsWithBare(
  List<String> lines,
  double? totalAmount,
) {
  final items = <LocalItem>[];
  final cands = <BareCandidate>[];
  final skipped = <LocalItem>[];
  var pendingName = ''; // üstteki satır yalnızca ürün adı (alttaki adet satırının kalemi olabilir)
  final rev = reversalLines(lines);
  for (var li = 0; li < lines.length; li++) {
    var l = lines[li];
    if (isTotalLabel(l)) break; // Toplam satırından sonrası ödeme/alt bilgi
    if (isCancelMarker(l)) {
      pendingName = ''; // "** IPTAL **" bir ürün adı değildir
      continue;
    }
    if (rev.contains(li)) {
      // Geri alma satırı ("KIVI *-69,22"): kalem eklenmez, iptal edilen önceki kalem düşülür.
      final na = nameAndAmount(l);
      if (na != null) applyReversal(items, na.name, na.amount);
      pendingName = '';
      continue;
    }
    final pending = pendingName;
    pendingName = '';
    final q = qtyPrefixRe.firstMatch(l);
    if (q != null) {
      final qty = q[1] == null ? 0.0 : (double.tryParse(q[1]!.replaceAll(',', '.')) ?? 0);
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
    if (lab.strong || lab.weak) {
      if (lab.weak) {
        final a = amountsIn(l);
        if (a.isNotEmpty) skipped.add(LocalItem(cleanItemName(l), a.last));
      }
      continue;
    }
    final masked = maskDates(l);
    final matches = amountRe.allMatches(masked).toList();
    if (matches.isEmpty) {
      final b = bareAmountRe.firstMatch(l);
      if (b != null) {
        final n = int.tryParse(b[1]!);
        if (n != null && n > 0) {
          final name = cleanItemName(l.substring(0, b.start));
          if (countLetters(name) >= 2) cands.add(BareCandidate(items.length, LocalItem(name, n / 100)));
        }
        continue;
      }
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
  return (items: items, bare: cands, skipped: skipped);
}

/// Kalem adındaki KDV oranı ve sütun kalıntılarını temizler ("...  %08 *" → ad).
String cleanItemName(String s) {
  s = trimRightChars(s.trim(), ' *+\$');
  s = s.replaceFirst(trailingXRe, '');
  s = s.replaceFirst(itemTailRe, '');
  return trimChars(s.trim(), '*-=_#:+\$ ');
}
