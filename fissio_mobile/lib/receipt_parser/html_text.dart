// HTML e-posta gövdesi → temiz fiş metni (saf Dart). Go ikizi: services/expense/internal/digital/htmltext.go + preamble.go
// (otorite Go'dur). Ortak vektörler: testdata/html/*.json ve testdata/preamble.json.
//
// Kurallar (iki tarafta aynı): head/style/script/noscript/template/svg/iframe/button/img… ve gizli öğeler atılır; blok öğeler
// satır sonu üretir, td/th hücreleri bir boşlukla ayrılır; boşluk dizileri tek boşluğa iner, boş satırlar atılır; altbilgi/
// yasal/sosyal medya/abonelik satırları atılır. "İlet (Forward)" önsözü [stripForwardPreamble] ile temizlenir.
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'normalize.dart' show foldTR;

const _skipTags = {
  'head', 'title', 'style', 'script', 'noscript', 'template', 'svg', 'iframe', 'object', 'button', 'select',
  'textarea', 'img', 'input', 'meta', 'link', //
};

const _blockTags = {
  'p', 'div', 'tr', 'li', 'ul', 'ol', 'table', 'thead', 'tbody', 'tfoot', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'br',
  'hr', 'section', 'article', 'header', 'footer', 'blockquote', 'pre', 'address', 'dl', 'dt', 'dd', 'center', 'main',
  'nav', 'aside', 'form', 'body', 'html', //
};

// Boşlukları atılmış, küçük harfli style değerinde gizlilik izi ("font-size:0.9em" gizli sayılmaz).
final RegExp _hiddenStyleRe = RegExp(r'display:none|visibility:hidden|(?:font-size|max-height|opacity):0(?:[^.\d]|$)');

const _footerMarkers = [
  'abonelikten', 'aboneligi', 'unsubscribe', 'e-posta tercih', 'gizlilik politika', 'kullanim kosul',
  'privacy policy', 'terms of service', 'terms of use', 'bu e-posta', 'bu eposta', 'bu mail', 'this email was sent',
  'this e-mail was sent', 'you are receiving this', 'you received this', 'view in browser', 'view this email',
  'tarayicida goruntule', 'tarayicinizda', 'tum haklari saklidir', 'all rights reserved', 'copyright', '©',
  'mersis', 'kvkk', 'kisisel verilerin', 'facebook', 'instagram', 'twitter', 'linkedin', 'youtube', 'tiktok',
  'follow us', 'bizi takip', 'do not reply', 'lutfen yanitlamayin', 'bu mesaj otomatik', //
];

/// HTML'i satır yapısı korunmuş saf metne çevirir. Çözümlenemezse boş metin.
String htmlToText(String src) {
  final dom.Document doc;
  try {
    doc = html_parser.parse(src);
  } catch (_) {
    return '';
  }
  final w = _TextWalker();
  w.walk(doc);
  w.flush();
  return _dropFooterLines(w.lines);
}

bool _isHidden(dom.Element n) {
  if (n.attributes.containsKey('hidden')) return true;
  final style = n.attributes['style'];
  if (style != null) {
    final s = style.replaceAll(RegExp(r'[ \t\n\r]'), '').toLowerCase();
    if (_hiddenStyleRe.hasMatch(s)) return true;
  }
  return false;
}

bool _isInvisibleSpace(int r) => r == 0xA0 || r == 0xAD || r == 0x34F || r == 0x200B || r == 0x200C || r == 0x200D || r == 0xFEFF;

/// Boşluk/sekme/satır sonu/nbsp dizilerini tek boşluğa indirir ve kırpar.
String _collapseSpaces(String s) {
  final b = StringBuffer();
  var space = false;
  var any = false;
  for (final r in s.runes) {
    if (r == 0x20 || r == 0x09 || r == 0x0A || r == 0x0D || r == 0x0C || _isInvisibleSpace(r)) {
      space = true;
      continue;
    }
    if (space && any) b.write(' ');
    space = false;
    any = true;
    b.writeCharCode(r);
  }
  return b.toString();
}

class _TextWalker {
  final StringBuffer cur = StringBuffer();
  final List<String> lines = [];

  void flush() {
    final s = _collapseSpaces(cur.toString());
    cur.clear();
    if (s.isNotEmpty) lines.add(s);
  }

  void walk(dom.Node n) {
    if (n is dom.Text) {
      cur.write(n.data);
      return;
    }
    if (n is dom.Element) {
      final tag = (n.localName ?? '').toLowerCase();
      if (_skipTags.contains(tag) || _isHidden(n)) return;
      final block = _blockTags.contains(tag);
      if (block) flush();
      for (final c in n.nodes) {
        walk(c);
      }
      if (block) flush();
      if (tag == 'td' || tag == 'th') cur.write(' ');
      return;
    }
    if (n is dom.Comment) return;
    for (final c in n.nodes) {
      walk(c);
    }
  }
}

String _dropFooterLines(List<String> lines) {
  final out = <String>[];
  for (final l in lines) {
    final f = foldTR(l);
    if (!_footerMarkers.any(f.contains)) out.add(l);
  }
  return out.join('\n');
}

// ---------------------------------------------------------------------------------------------------------------------
// "İlet (Forward)" önsözü

final RegExp _fwdMarkerRe =
    RegExp(r'forwarded message|begin forwarded|iletilen ileti|iletilmis mesaj|original message|orijinal mesaj|orijinal ileti');
final RegExp _hdrLineRe = RegExp(
  r'^(?:from|to|cc|bcc|date|sent|subject|reply-to|gonderen|kimden|kime|alici|konu|tarih|gonderilme|gonderim tarihi|gonderildi|gonderilme tarihi)\s*:',
);
final RegExp _hdrFromRe = RegExp(r'^(?:from|gonderen|kimden)\s*:');
final RegExp _quotePfxRe = RegExp(r'^(?:>\s?)+');

/// Mail iletirken eklenen önsözü atar: "---------- Forwarded message ---------", "Begin forwarded message:", "İletilen
/// ileti", Outlook "From:/Sent:/To:/Subject:" başlık bloğu ve satır başı ">" alıntı işaretleri. Yoksa metin olduğu gibi kalır.
String stripForwardPreamble(String text) {
  final lines = text.replaceAll('\r', '').split('\n');

  var nonEmpty = 0;
  var quoted = 0;
  for (final l in lines) {
    final t = l.trim();
    if (t.isEmpty) continue;
    nonEmpty++;
    if (t.startsWith('>')) quoted++;
  }
  if (nonEmpty > 0 && quoted * 2 >= nonEmpty) {
    for (var i = 0; i < lines.length; i++) {
      lines[i] = lines[i].trim().replaceFirst(_quotePfxRe, '').trim();
    }
  }

  final limit = lines.length > 60 ? 60 : lines.length;
  var cut = -1;
  for (var i = 0; i < limit; i++) {
    if (_fwdMarkerRe.hasMatch(foldTR(lines[i]))) {
      cut = _skipHeaderBlock(lines, i + 1);
      break;
    }
  }
  if (cut < 0) {
    var start = 0;
    while (start < lines.length && lines[start].trim().isEmpty) {
      start++;
    }
    final end = _skipHeaderBlock(lines, start);
    var count = 0;
    var hasFrom = false;
    for (var k = start; k < end; k++) {
      final f = foldTR(lines[k].trim());
      if (_hdrLineRe.hasMatch(f)) {
        count++;
        if (_hdrFromRe.hasMatch(f)) hasFrom = true;
      }
    }
    if (count >= 3 && hasFrom) cut = end;
  }
  final rest = cut > 0 ? lines.sublist(cut) : lines;
  return rest.join('\n').trim();
}

int _skipHeaderBlock(List<String> lines, int from) {
  var j = from;
  while (j < lines.length) {
    final t = lines[j].trim();
    if (t.isEmpty) {
      j++;
      continue;
    }
    if (_hdrLineRe.hasMatch(foldTR(t))) {
      j++;
      continue;
    }
    break;
  }
  return j;
}
