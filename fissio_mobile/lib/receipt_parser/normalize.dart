// Go `services/expense/normalize.go` + `parser.go` yardımcılarının Dart portu. Davranış birebir aynı
// tutulur (aynı test vektörleri): cihaz içi OCR çevrimdışıyken sunucunun ayrıştırıcısıyla aynı sonucu vermeli.

const int fuzzyMinLen = 5; // bu uzunluktan kısa anahtar kelimeler bulanık eşleşmez
const int fuzzyTwoEditLen = 8; // bu uzunluk ve üzeri: 2 düzenleme, aksi halde 1

final RegExp _letterRe = RegExp(r'\p{L}', unicode: true);
final RegExp _lowerRe = RegExp(r'\p{Ll}', unicode: true);
final RegExp _digitRe = RegExp(r'\p{Nd}', unicode: true);
final RegExp _ws = RegExp(r'\s+');
final RegExp _notLetter = RegExp(r'[^\p{L}]+', unicode: true);
final RegExp _notAlnum = RegExp(r'[^\p{L}\p{Nd}]+', unicode: true);

bool isLetterCh(String ch) => ch.isNotEmpty && _letterRe.hasMatch(ch);
bool isDigitCh(String ch) => ch.isNotEmpty && _digitRe.hasMatch(ch);
bool isLowerCh(String ch) => ch.isNotEmpty && _lowerRe.hasMatch(ch);

List<String> _chars(String s) => [for (final r in s.runes) String.fromCharCode(r)];

/// Boşlukla bölünmüş boş olmayan parçalar (Go `strings.Fields`).
List<String> fields(String s) => s.split(_ws).where((e) => e.isNotEmpty).toList();

double round2(double v) => (v * 100).roundToDouble() / 100;

int countLetters(String s) => _letterRe.allMatches(s).length;

/// Go `strings.Trim(s, cutset)`.
String trimChars(String s, String cutset) {
  var a = 0, b = s.length;
  while (a < b && cutset.contains(s[a])) {
    a++;
  }
  while (b > a && cutset.contains(s[b - 1])) {
    b--;
  }
  return s.substring(a, b);
}

String trimRightChars(String s, String cutset) {
  var b = s.length;
  while (b > 0 && cutset.contains(s[b - 1])) {
    b--;
  }
  return s.substring(0, b);
}

/// Türkçe karakterleri ASCII'ye indirger ve küçük harfe çevirir (OCR ve büyük/küçük harf toleransı).
String foldTR(String s) {
  const map = {
    'İ': 'i', 'I': 'i', 'ı': 'i', 'Ç': 'c', 'ç': 'c', 'Ğ': 'g', 'ğ': 'g',
    'Ö': 'o', 'ö': 'o', 'Ş': 's', 'ş': 's', 'Ü': 'u', 'ü': 'u',
  };
  final sb = StringBuffer();
  for (final ch in _chars(s)) {
    sb.write(map[ch] ?? ch);
  }
  return sb.toString().toLowerCase();
}

const Map<String, String> _ocrDigitFix = {'0': 'o', '1': 'i', '5': 's', '8': 'b'};

/// Termal fişlerde harf yerine okunan rakamları (0→o, 1→i, 5→s, 8→b) düzeltir; yalnızca TEK rakam
/// içeren ve en az 3 harfli token'lara uygulanır. Yalnızca eşleştirme kopyası içindir.
String normalizeOCR(String s) => fields(s).map(_fixToken).join(' ');

String _fixToken(String t) {
  final cs = _chars(t);
  final digits = cs.where(isDigitCh).length;
  final letters = cs.where(isLetterCh).length;
  if (digits != 1 || letters < 3) return t;
  return cs.map((c) => isDigitCh(c) ? (_ocrDigitFix[c] ?? c) : c).join();
}

const Set<String> _currencyPrefixes = {'US', 'CA', 'AU', 'NZ', 'HK', 'SG'};

/// OCR'ın Türkçe harf yerine okuduğu `$` gliflerini bağlama göre düzeltir (FI$ → FİŞ gibi: `$` → ş/Ş).
/// Rakamdan hemen önce gelen `$` fiyat işaretidir ve korunur. İdempotenttir.
String fixTurkishGlyphs(String s) {
  if (!s.contains(r'$')) return s;
  final r = _chars(s);
  String at(int i) => (i < 0 || i >= r.length) ? '' : r[i];
  for (var i = 0; i < r.length; i++) {
    if (r[i] != r'$') continue;
    final prev = at(i - 1), next = at(i + 1);
    if (isDigitCh(next)) continue;
    if (!isLetterCh(next)) {
      var start = i;
      while (start > 0 && isLetterCh(r[start - 1])) {
        start--;
      }
      if (_currencyPrefixes.contains(r.sublist(start, i).join().toUpperCase())) continue;
    }
    String ref;
    if (isLetterCh(next)) {
      ref = next;
    } else if (isLetterCh(prev)) {
      ref = prev;
    } else if (prev == '.' && isLetterCh(at(i - 2)) && !isLetterCh(at(i - 3))) {
      ref = at(i - 2); // A.$. → A.Ş.
    } else {
      continue;
    }
    r[i] = isLowerCh(ref) ? 'ş' : 'Ş';
  }
  return r.join();
}

int levenshtein(String a, String b) {
  final ra = _chars(a), rb = _chars(b);
  if (ra.isEmpty) return rb.length;
  if (rb.isEmpty) return ra.length;
  var prev = List<int>.generate(rb.length + 1, (j) => j);
  var cur = List<int>.filled(rb.length + 1, 0);
  for (var i = 1; i <= ra.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= rb.length; j++) {
      final cost = ra[i - 1] == rb[j - 1] ? 0 : 1;
      var m = prev[j] + 1;
      if (cur[j - 1] + 1 < m) m = cur[j - 1] + 1;
      if (prev[j - 1] + cost < m) m = prev[j - 1] + cost;
      cur[j] = m;
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[rb.length];
}

int _maxEdits(int kwLen) => kwLen >= fuzzyTwoEditLen ? 2 : 1;

/// Metindeki bir token'in (çok kelimeli anahtarlarda ardışık token birleşimi) anahtar kelimeye izin
/// verilen düzenleme mesafesi içinde olup olmadığına bakar. text ve kw foldTR'den geçmiş olmalı.
bool fuzzyTokenMatch(String text, String kw, int minLen) {
  if (_chars(kw).length < minLen) return false;
  final limit = _maxEdits(_chars(kw).length);
  final n = fields(kw).length;
  final toks = fields(text);
  if (n == 0) return false;
  for (var i = 0; i + n <= toks.length; i++) {
    if (levenshtein(toks.sublist(i, i + n).join(' '), kw) <= limit) return true;
  }
  return false;
}

/// Ham satırda anahtar kelimeyi arar: düz/OCR-düzeltilmiş alt dize ya da bulanık eşleşme. kw foldTR formunda.
bool hasKeyword(String line, String kw, int minFuzzyLen) {
  final f = foldTR(line);
  if (f.contains(kw)) return true;
  final n = normalizeOCR(f);
  if (n.contains(kw)) return true;
  return fuzzyTokenMatch(n, kw, minFuzzyLen);
}

bool _isAlnumAscii(String ch) {
  final c = ch.codeUnitAt(0);
  return (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39);
}

/// Kelime sınırına saygıyla arar ("bp", "abpx" içinde eşleşmesin).
bool containsWord(String text, String word) {
  if (word.isEmpty) return false;
  var from = 0;
  while (true) {
    final i = text.indexOf(word, from);
    if (i < 0) return false;
    final end = i + word.length;
    final beforeOK = i == 0 || !_isAlnumAscii(text[i - 1]);
    final afterOK = end == text.length || !_isAlnumAscii(text[end]);
    if (beforeOK && afterOK) return true;
    from = i + 1;
  }
}

bool containsWordFuzzy(String text, String word) {
  if (containsWord(text, word)) return true;
  final n = normalizeOCR(text);
  if (containsWord(n, word)) return true;
  return fuzzyTokenMatch(n, word, fuzzyMinLen);
}

/// Satırdaki kelimelerden (harf/rakam dışı karakterlerle bölünmüş) biri tok ise true ("TOPKDV" ≠ "top").
bool hasToken(String line, String tok) => foldTR(line).split(_notAlnum).any((t) => t == tok);

/// KDV satırı (OCR sık sık KDV'yi KDU/KDY/KOV okur).
bool isKDVLine(String line) {
  if (hasKeyword(line, 'kdv', fuzzyMinLen)) return true;
  for (final t in foldTR(line).split(_notLetter)) {
    if (t.length == 3 && t[0] == 'k' && levenshtein(t, 'kdv') <= 1) return true;
  }
  return false;
}

/// "** ELEKTRIK KESILDI **" gibi yıldızla sarılmış bilgi satırı.
bool isStarBanner(String line) {
  final t = line.trim();
  return t.startsWith('**') && t.endsWith('**');
}

/// Satır başındaki telefon/numara kalıntılarını ("/05445020217 BIRLESIK ...") atar.
String dropLeadingJunk(String l) {
  final toks = fields(l);
  while (toks.length > 1) {
    final digits = _chars(toks[0]).where(isDigitCh).length;
    if (digits >= 4 || toks[0].startsWith('/')) {
      toks.removeAt(0);
      continue;
    }
    break;
  }
  return toks.join(' ');
}
