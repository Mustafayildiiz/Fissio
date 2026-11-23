// Go `internal/receiptparse/cancel.go` portu: iptal / iade geri alma satırları.
//
// Market fişlerinde bir kalem "** IPTAL **" satırıyla geri alınır. Geri alma satırı kalemin ADINI ve ters tutarı
// ("KIVI *-69,22") taşır; OCR bazen eksi işaretini okuyamaz ya da tutarı bozar ("59,22"). Gerçek akış: satış satırı +
// IPTAL işareti + (miktar satırı) + geri alma satırı. Geri alma satırı ne kalem ne de indirimdir: önceki kalemi düşürür.
import 'merge.dart' show jaroWinkler;
import 'normalize.dart';
import 'parser.dart' show LocalItem, amountRe, amountsIn, cleanItemName, maskDates, parseAmount;
import 'reconcile.dart' show approxEq;
import 'summary.dart' show isTotalLabel, letterTokens;

/// Tutarsız "IPTAL" / "IADE" işaret satırı ("** IPTAL **", "IPTAL**").
bool isCancelMarker(String l) {
  if (amountsIn(l).isNotEmpty) return false;
  for (final t in letterTokens(l)) {
    if (t == 'iptal' || t == 'iade' || (t.length == 5 && levenshtein(t, 'iptal') <= 1)) return true;
  }
  return false;
}

/// Her iptal işaretinden sonraki (en fazla 4 satır içinde) ilk "ad + tutar" satırının indeksi. Arada kalan
/// yalnız-miktar satırları ("-0,770 X 89,90 TL") atlanır.
Set<int> reversalLines(List<String> lines) {
  final out = <int>{};
  for (var i = 0; i < lines.length; i++) {
    if (!isCancelMarker(lines[i])) continue;
    for (var j = i + 1; j < lines.length && j <= i + 4; j++) {
      if (isTotalLabel(lines[j])) break;
      if (nameAndAmount(lines[j]) != null) {
        out.add(j);
        break;
      }
    }
  }
  return out;
}

/// Satırın sonundaki tutar ve solundaki (temizlenmiş) ürün adı; ad en az iki harf değilse null.
({String name, double amount})? nameAndAmount(String l) {
  final masked = maskDates(l);
  final m = amountRe.allMatches(masked).toList();
  if (m.isEmpty) return null;
  final last = m.last;
  final v = parseAmount(masked.substring(last.start, last.end));
  if (v == null) return null;
  final name = cleanItemName(l.substring(0, last.start));
  if (countLetters(name) < 2) return null;
  return (name: name, amount: v);
}

/// Geri alma satırının iptal ettiği kalemi listeden düşürür: son 4 kalem içinde aynı tutarlı olan, yoksa (tutar
/// bozuk okunmuş olabilir) adı benzeyen SON kalem. Eşleşme yoksa dokunmaz (mutabakat uyuşmazlığı bayraklar).
void applyReversal(List<LocalItem> items, String name, double amount) {
  var drop = -1;
  for (var i = items.length - 1; i >= 0 && i >= items.length - 4; i--) {
    if (approxEq(items[i].amount, amount)) {
      drop = i;
      break;
    }
  }
  if (drop < 0 && items.isNotEmpty && _similarNames(items.last.name, name)) drop = items.length - 1;
  if (drop >= 0) items.removeAt(drop);
}

bool _similarNames(String a, String b) {
  final fa = foldTR(a), fb = foldTR(b);
  if (fa.isEmpty || fb.isEmpty) return false;
  return levenshtein(fa, fb) <= 2 || jaroWinkler(fa, fb) >= 0.7;
}
