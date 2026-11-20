// Go `services/expense/summary.go` portu: özet/bilgi satırlarını (TOPLAM, ARA TOPLAM, KDV, İNDİRİM,
// NAKİT, KART, PARA ÜSTÜ…) tanır; bunlar asla kalem olmaz. Mobilde yalnızca toplam indirim hesaplanır.
import 'cancel.dart' show reversalLines;
import 'normalize.dart';
import 'parser.dart' show amountsIn, maskDates;

/// Eksi işaretli tutar ("-5,00", "* -12,50"): ürün satırları negatif olmaz, indirim/iadedir.
final RegExp negativeAmountRe = RegExp(r'(?:^|[\s*:])-\s*(?:\d{1,3}(?:\.\d{3})+|\d+)[.,]\d{2}\b');

const List<String> strongNonItemLabels = [
  'toplam', 'topkdv', 'odenecek', 'para ustu', 'fis no', 'mersis', 'tesekkur',
  'kredi kart', 'banka kart', 'provizyon', 'nakit',
];

/// Kısa etiketler YALNIZCA tam kelime olarak eşleşir ("kart" KARTON SÜT'ü düşürmesin).
const Set<String> weakNonItemTokens = {
  'tutar', 'tutari', 'kredi', 'kart', 'karti', 'tarih', 'tarihi', 'saat', 'vkn', 'vergi',
  'banka', 'bankasi', 'onay', 'onayi',
};

final RegExp _notLetterRe = RegExp(r'[^\p{L}]+', unicode: true);

/// Satırı yalnızca harf dizilerine böler ("TARIH12.12.2019" → [tarih]).
List<String> letterTokens(String line) =>
    normalizeOCR(foldTR(line)).split(_notLetterRe).where((e) => e.isNotEmpty).toList();

/// Boşluksuz yazılmış etiketi KELİME BAŞINDAN başlayarak arar ("ARATOPLAM", "PARAUSTU", "KREDIKARTI").
bool hasPhrase(String line, String needle) {
  final toks = letterTokens(line);
  for (var i = 0; i < toks.length; i++) {
    if (toks.sublist(i).join().startsWith(needle)) return true;
  }
  return false;
}

bool isSubtotalLine(String l) =>
    hasPhrase(l, 'aratop') || fuzzyTokenMatch(normalizeOCR(foldTR(l)), 'ara toplam', fuzzyMinLen);

const List<String> discountTokens = ['indirim', 'indirimi', 'iskonto', 'iskontosu'];

bool isDiscountLine(String l) {
  if (negativeAmountRe.hasMatch(maskDates(l))) return true;
  for (final t in letterTokens(l)) {
    for (final d in discountTokens) {
      if (t == d || (t.length == d.length && levenshtein(t, d) <= 1)) return true;
    }
  }
  return false;
}

/// Genel toplam satırı (ARA TOPLAM ve TOPLAM İNDİRİM hariç).
bool isTotalLabel(String l) =>
    (hasKeyword(l, 'toplam', fuzzyMinLen) || hasToken(l, 'top')) && !isSubtotalLine(l) && !isDiscountLine(l);

/// strong: kesin etiket; weak: yalnızca kısa bir kelime eşleşti.
({bool strong, bool weak}) nonItemLabel(String l) {
  if (isKDVLine(l) || isSubtotalLine(l) || isDiscountLine(l)) return (strong: true, weak: false);
  for (final kw in strongNonItemLabels) {
    if (hasKeyword(l, kw, 6) || hasPhrase(l, kw.replaceAll(' ', ''))) return (strong: true, weak: false);
  }
  for (final t in letterTokens(l)) {
    if (weakNonItemTokens.contains(t)) return (strong: false, weak: true);
  }
  return (strong: false, weak: false);
}

int itemRegionEnd(List<String> lines) {
  for (var i = 0; i < lines.length; i++) {
    if (isTotalLabel(lines[i])) return i;
  }
  return lines.length;
}

/// Kalemlerden düşülecek indirim toplamı. Yalnızca kalem bölgesinden (genel toplamdan önce) alınır; tek
/// tek indirim satırı varsa "TOPLAM İNDİRİM" özeti çift sayılmasın diye yok sayılır.
double extractDiscount(List<String> lines) {
  final end = itemRegionEnd(lines);
  final individual = <double>[], recap = <double>[];
  final rev = reversalLines(lines);
  for (var i = 0; i < lines.length; i++) {
    final a = amountsIn(lines[i]);
    // İptal geri alma satırı indirim değildir (kalem olarak düşülür).
    if (a.isEmpty || rev.contains(i) || !isDiscountLine(lines[i]) || i >= end) continue;
    if (hasKeyword(lines[i], 'toplam', fuzzyMinLen)) {
      recap.add(a.last);
    } else {
      individual.add(a.last);
    }
  }
  final list = individual.isNotEmpty ? individual : recap;
  return round2(list.fold<double>(0, (s, v) => s + v));
}
