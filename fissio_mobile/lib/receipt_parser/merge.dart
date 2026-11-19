// Go `services/expense/merge.go` portu: çok sayfalı fişte sayfa metinlerini tek metne birleştirir. Dikiş
// yalnızca en az 2 ardışık satır çakışıyorsa silinir (BIM gibi fişlerde meşru bitişik tekrarlar var).
// Ortak vektörler: `testdata/merge.json` (Go `golden_parse_test.go`, Dart `merge_pages_test.dart`).
import 'normalize.dart';
import 'parser.dart' show amountsIn, splitLines;

const int seamMaxOverlap = 6; // dikişte aranacak en fazla çakışan satır sayısı
const int seamMinOverlap = 2; // bu kadar ardışık satır çakışmadıkça hiçbir şey silinmez
const double seamJaroWinkler = 0.92;
const int seamCropMinChars = 6; // soldan kırpılmış satırda kalan parçanın en az harf sayısı

String mergePageTexts(List<String> pages) {
  final merged = <String>[];
  for (final p in pages) {
    var lines = splitLines(p);
    if (lines.isEmpty) continue;
    if (merged.isNotEmpty) lines = lines.sublist(_seamOverlap(merged, lines));
    merged.addAll(lines);
  }
  return merged.join('\n');
}

/// Sonraki sayfadan atılacak baş satır sayısı (0 = çakışma yok). Fotoğraf bir satırın ortasından kesildiyse
/// sonraki sayfanın ilk satırı yarım kalır; o parça satır atlanarak da eşleşme aranır ve birlikte atılır.
int _seamOverlap(List<String> prev, List<String> next) {
  var bestDrop = 0, bestK = 0;
  for (var skip = 0; skip <= 1; skip++) {
    var maxK = seamMaxOverlap;
    if (prev.length < maxK) maxK = prev.length;
    if (next.length - skip < maxK) maxK = next.length - skip;
    for (var k = maxK; k >= seamMinOverlap && k > bestK; k--) {
      var ok = true;
      for (var i = 0; i < k; i++) {
        if (!fuzzyLineEqual(prev[prev.length - k + i], next[skip + i])) {
          ok = false;
          break;
        }
      }
      if (ok) {
        bestDrop = skip + k;
        bestK = k;
        break;
      }
    }
  }
  return bestDrop;
}

/// Aynı satırın iki fotoğrafta okunmuş halini eşleştirir: tutarlar birebir aynı olmalı; metin için Levenshtein
/// (~1/6), Jaro-Winkler (yakın uzunluk) ya da soldan kırpılmış sonek eşleşmesinden biri yeterli.
bool fuzzyLineEqual(String a, String b) {
  final fa = foldTR(a).replaceAll(' ', '');
  final fb = foldTR(b).replaceAll(' ', '');
  if (fa.isEmpty || fb.isEmpty) return false;
  final amtA = amountsIn(a), amtB = amountsIn(b);
  if (!_sameAmounts(amtA, amtB)) return false;
  final la = fa.runes.length, lb = fb.runes.length;
  var limit = la ~/ 6;
  if (limit < 1) limit = 1;
  if (levenshtein(fa, fb) <= limit) return true;
  final lo = la < lb ? la : lb, hi = la > lb ? la : lb;
  if (lo * 5 >= hi * 4 && jaroWinkler(fa, fb) >= seamJaroWinkler) return true;
  if (amtA.isNotEmpty) {
    var short = fa, long = fb;
    if (lb < la) {
      short = fb;
      long = fa;
    }
    if (long.endsWith(short) && countLetters(short) >= seamCropMinChars) return true;
  }
  return false;
}

bool _sameAmounts(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 0.005) return false;
  }
  return true;
}

/// Jaro-Winkler benzerliği (0..1, rune bazlı); Go `jaroWinkler` ile aynı.
double jaroWinkler(String a, String b) {
  final ra = a.runes.toList(), rb = b.runes.toList();
  final la = ra.length, lb = rb.length;
  if (la == 0 && lb == 0) return 1;
  if (la == 0 || lb == 0) return 0;
  var window = (la > lb ? la : lb) ~/ 2 - 1;
  if (window < 0) window = 0;
  final ma = List<bool>.filled(la, false), mb = List<bool>.filled(lb, false);
  var matches = 0;
  for (var i = 0; i < la; i++) {
    final lo = i - window < 0 ? 0 : i - window;
    final hi = i + window > lb - 1 ? lb - 1 : i + window;
    for (var j = lo; j <= hi; j++) {
      if (!mb[j] && ra[i] == rb[j]) {
        ma[i] = true;
        mb[j] = true;
        matches++;
        break;
      }
    }
  }
  if (matches == 0) return 0;
  var trans = 0, k = 0;
  for (var i = 0; i < la; i++) {
    if (!ma[i]) continue;
    while (!mb[k]) {
      k++;
    }
    if (ra[i] != rb[k]) trans++;
    k++;
  }
  final m = matches.toDouble();
  final jaro = (m / la + m / lb + (m - trans / 2) / m) / 3;
  var prefix = 0;
  final maxPrefix = [4, la, lb].reduce((x, y) => x < y ? x : y);
  while (prefix < maxPrefix && ra[prefix] == rb[prefix]) {
    prefix++;
  }
  return jaro + prefix * 0.1 * (1 - jaro);
}
