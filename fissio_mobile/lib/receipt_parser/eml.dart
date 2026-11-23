// .eml (RFC 5322 / MIME) ayrıştırıcı — saf Dart, eklentisiz. Go ikizi: services/expense/internal/digital/eml.go (otorite Go);
// ortak vektörler testdata/eml/*.json.
//
// Desteklenen: katlanmış başlıklar, RFC 2047 kodlu sözcükler, multipart/* (iç içe), message/rfc822 (ek olarak iletilmiş mail),
// quoted-printable / base64, utf-8 / windows-1254 (= iso-8859-9) / latin1 karakter kümeleri, PDF ekleri ve zip içindeki PDF'ler.
// Çıktı yalnızca fiş okumaya yarayan alanları taşır (konu, gönderen, gövdeler, PDF ekleri); alıcı çözümü sunucunun işidir.
import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

const _maxEmlBytes = 30 << 20;
const _maxAttachmentBytes = 20 << 20;
const _maxPdfsPerMail = 5;
const _maxMimeDepth = 6;

/// E-postadan çıkan PDF eki (zip içinden gelenler dahil).
class EmlAttachment {
  final String name;
  final Uint8List bytes;
  const EmlAttachment(this.name, this.bytes);
}

/// Ayrıştırılmış e-posta.
class EmlMessage {
  String subject;
  String from;
  String messageId;

  /// text/plain gövde(ler) ve ham text/html gövde(ler).
  String text;
  String html;
  final List<EmlAttachment> pdfs;
  EmlMessage({this.subject = '', this.from = '', this.messageId = '', this.text = '', this.html = '', List<EmlAttachment>? pdfs})
    : pdfs = pdfs ?? [];
}

class EmlException implements Exception {
  final String message;
  const EmlException(this.message);
  @override
  String toString() => 'EmlException: $message';
}

/// Ham .eml baytlarını ayrıştırır. Başlık bloğu yoksa [EmlException].
EmlMessage parseEml(Uint8List raw) {
  if (raw.length > _maxEmlBytes) throw const EmlException('eml too large');
  final text = latin1.decode(raw); // bayt başına bir karakter: gövdeler sonradan karakter kümesine göre çözülür
  final part = _splitPart(text);
  if (part.headers.isEmpty) throw const EmlException('no headers');
  final m = EmlMessage(
    subject: _decodeHeader(part.header('subject')),
    from: _decodeHeader(part.header('from')),
    messageId: part.header('message-id').trim(),
  );
  _walk(m, part, 0);
  m.text = m.text.trim();
  m.html = m.html.trim();
  return m;
}

class _Part {
  final Map<String, List<String>> headers;
  final String body;
  _Part(this.headers, this.body);
  String header(String k) => (headers[k.toLowerCase()] ?? const ['']).first;
}

/// Başlık/gövde ayrımı (satır sonları "\n"e normalize edilir; katlanmış başlıklar birleştirilir).
_Part _splitPart(String raw) {
  final s = raw.replaceAll('\r\n', '\n');
  final i = s.indexOf('\n\n');
  final head = i >= 0 ? s.substring(0, i) : s;
  final body = i >= 0 ? s.substring(i + 2) : '';
  final headers = <String, List<String>>{};
  String? key;
  final buf = StringBuffer();
  void commit() {
    if (key != null) headers.putIfAbsent(key!, () => []).add(buf.toString().trim());
    buf.clear();
    key = null;
  }

  for (final line in head.split('\n')) {
    if (line.isEmpty) continue;
    if ((line.startsWith(' ') || line.startsWith('\t')) && key != null) {
      buf.write(' ${line.trim()}');
      continue;
    }
    final c = line.indexOf(':');
    if (c <= 0) continue;
    commit();
    key = line.substring(0, c).trim().toLowerCase();
    buf.write(line.substring(c + 1));
  }
  commit();
  return _Part(headers, body);
}

// ---- başlık çözme -------------------------------------------------------------------------------------------------

final RegExp _encodedWord = RegExp(r'=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?=');

String _decodeHeader(String raw) {
  // Başlık 8 bit UTF-8 olarak yazılmışsa (RFC 6532) latin1'den geri çevir.
  var s = raw;
  if (s.codeUnits.any((c) => c > 0x7f)) {
    try {
      s = utf8.decode(latin1.encode(s));
    } catch (_) {}
  }
  s = s.replaceAllMapped(RegExp(r'(\?=)\s+(?==\?)'), (m) => m[1]!); // bitişik kodlu sözcükler arası boşluk atılır
  return s.replaceAllMapped(_encodedWord, (m) {
    final charset = m[1]!;
    final enc = m[2]!.toLowerCase();
    final data = m[3]!;
    try {
      final bytes = enc == 'b' ? base64.decode(_padBase64(data)) : _decodeQ(data);
      return _decodeCharset(charset, bytes);
    } catch (_) {
      return m[0]!;
    }
  });
}

Uint8List _decodeQ(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x5F) {
      out.add(0x20);
    } else if (c == 0x3D && i + 2 < s.length + 0 && _isHex(s, i + 1)) {
      out.add(int.parse(s.substring(i + 1, i + 3), radix: 16));
      i += 2;
    } else {
      out.add(c);
    }
  }
  return Uint8List.fromList(out);
}

bool _isHex(String s, int i) => i + 1 < s.length + 0 && RegExp(r'^[0-9A-Fa-f]{2}$').hasMatch(s.substring(i, i + 2));

String _padBase64(String s) {
  final t = s.replaceAll(RegExp(r'\s'), '');
  return t.padRight(t.length + (4 - t.length % 4) % 4, '=');
}

// ---- Content-Type -------------------------------------------------------------------------------------------------

class _Media {
  final String type;
  final Map<String, String> params;
  _Media(this.type, this.params);
}

_Media _parseMedia(String v) {
  if (v.trim().isEmpty) return _Media('', {});
  final parts = _splitParams(v);
  final params = <String, String>{};
  for (final p in parts.skip(1)) {
    final i = p.indexOf('=');
    if (i <= 0) continue;
    var val = p.substring(i + 1).trim();
    if (val.length >= 2 && val.startsWith('"') && val.endsWith('"')) val = val.substring(1, val.length - 1);
    params[p.substring(0, i).trim().toLowerCase()] = val;
  }
  return _Media(parts.first.trim().toLowerCase(), params);
}

/// ';' ile böler (tırnak içindekileri bölmez).
List<String> _splitParams(String v) {
  final out = <String>[];
  final b = StringBuffer();
  var q = false;
  for (final r in v.runes) {
    final ch = String.fromCharCode(r);
    if (ch == '"') q = !q;
    if (ch == ';' && !q) {
      out.add(b.toString());
      b.clear();
    } else {
      b.write(ch);
    }
  }
  out.add(b.toString());
  return out;
}

// ---- gövde çözme --------------------------------------------------------------------------------------------------

Uint8List _decodeBody(_Part p) {
  final cte = p.header('content-transfer-encoding').trim().toLowerCase();
  if (cte == 'base64') {
    try {
      return base64.decode(_padBase64(p.body));
    } catch (_) {
      return Uint8List(0);
    }
  }
  if (cte == 'quoted-printable') return _decodeQuotedPrintable(p.body);
  return Uint8List.fromList(latin1.encode(p.body));
}

Uint8List _decodeQuotedPrintable(String s) {
  final out = <int>[];
  final hex = RegExp(r'^[0-9A-Fa-f]{2}$');
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c == 0x3D) {
      if (i + 1 < s.length && s[i + 1] == '\n') {
        i += 2; // yumuşak satır sonu
        continue;
      }
      if (i + 2 < s.length + 0 && hex.hasMatch(s.substring(i + 1, i + 3))) {
        out.add(int.parse(s.substring(i + 1, i + 3), radix: 16));
        i += 3;
        continue;
      }
    }
    out.add(c);
    i++;
  }
  return Uint8List.fromList(out);
}

// windows-1254 (iso-8859-9 etiketi de buna eşlenir; Go htmlindex ile aynı): 0x80–0x9F aralığı.
const Map<int, int> _cp1254High = {
  0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6,
  0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D,
  0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
  0x9F: 0x0178, //
};
const Map<int, int> _cp1254Tr = {0xD0: 0x011E, 0xDD: 0x0130, 0xDE: 0x015E, 0xF0: 0x011F, 0xFD: 0x0131, 0xFE: 0x015F};

String _decodeCp1254(List<int> bytes) {
  final b = StringBuffer();
  for (final c in bytes) {
    b.writeCharCode(_cp1254High[c] ?? _cp1254Tr[c] ?? c);
  }
  return b.toString();
}

/// Karakter kümesi etiketine göre baytları metne çevirir (etiket yoksa/geçersiz UTF-8 ise windows-1254 denenir).
String _decodeCharset(String label, List<int> bytes) {
  var l = label.trim().toLowerCase();
  if (l.isEmpty || l == 'utf-8' || l == 'utf8' || l == 'us-ascii') {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return _decodeCp1254(bytes);
    }
  }
  if (l == 'windows-1254' || l == 'iso-8859-9' || l == 'latin5' || l == 'cp1254') return _decodeCp1254(bytes);
  if (l == 'iso-8859-1' || l == 'latin1' || l == 'windows-1252') return latin1.decode(bytes);
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes);
  }
}

// ---- yürüyüş ------------------------------------------------------------------------------------------------------

void _walk(EmlMessage m, _Part part, int depth) {
  if (depth > _maxMimeDepth) return;
  final ct = _parseMedia(part.header('content-type'));
  final type = ct.type.isEmpty ? 'text/plain' : ct.type;
  final disp = _parseMedia(part.header('content-disposition'));
  final name = _decodeHeader(disp.params['filename'] ?? ct.params['name'] ?? '');

  if (type.startsWith('multipart/')) {
    final boundary = ct.params['boundary'];
    if (boundary == null || boundary.isEmpty) return;
    for (final sub in _splitMultipart(part.body, boundary)) {
      _walk(m, _splitPart(sub), depth + 1);
    }
  } else if (type == 'message/rfc822') {
    final inner = _splitPart(latin1.decode(_decodeBody(part)));
    if (inner.headers.isNotEmpty) _walk(m, inner, depth + 1);
  } else if (type == 'application/pdf' || (name.toLowerCase().endsWith('.pdf') && !type.startsWith('text/'))) {
    _addPdf(m, name, _decodeBody(part));
  } else if (type == 'application/zip' || type == 'application/x-zip-compressed' || name.toLowerCase().endsWith('.zip')) {
    final data = _decodeBody(part);
    if (data.length > _maxAttachmentBytes) return;
    for (final a in extractZipPdfs(data, _maxPdfsPerMail - m.pdfs.length)) {
      m.pdfs.add(a);
    }
  } else if (type == 'text/plain' || type == 'text/html') {
    if (disp.type == 'attachment' && name.isNotEmpty) return;
    final s = _decodeCharset(ct.params['charset'] ?? '', _decodeBody(part));
    if (type == 'text/html') {
      m.html += '$s\n';
    } else {
      m.text += '$s\n';
    }
  }
}

void _addPdf(EmlMessage m, String name, Uint8List data) {
  if (m.pdfs.length >= _maxPdfsPerMail || data.isEmpty || data.length > _maxAttachmentBytes) return;
  m.pdfs.add(EmlAttachment(name, data));
}

/// Gövdeyi `--boundary` satırlarına göre böler (kapanış `--boundary--`); parçaların son satır sonu atılır.
List<String> _splitMultipart(String body, String boundary) {
  final delim = '--$boundary';
  final parts = <String>[];
  StringBuffer? cur;
  for (final line in body.split('\n')) {
    final t = line.trimRight();
    if (t == '$delim--') {
      if (cur != null) parts.add(_trimOneNewline(cur.toString()));
      cur = null;
      break;
    }
    if (t == delim) {
      if (cur != null) parts.add(_trimOneNewline(cur.toString()));
      cur = StringBuffer();
      continue;
    }
    cur?.write('$line\n');
  }
  if (cur != null) parts.add(_trimOneNewline(cur.toString()));
  return parts;
}

String _trimOneNewline(String s) => s.endsWith('\n') ? s.substring(0, s.length - 1) : s;

// ---- zip ----------------------------------------------------------------------------------------------------------

/// Zip arşivindeki .pdf dosyalarını (en çok [max] adet, her biri ≤20 MB) çıkarır; bozuk arşivde boş döner.
/// Yalnızca saklanmış (0) ve deflate (8) yöntemleri desteklenir.
List<EmlAttachment> extractZipPdfs(Uint8List data, int max) {
  if (max <= 0 || data.length < 22 || data.length > _maxAttachmentBytes) return const [];
  final bd = ByteData.sublistView(data);
  // Merkez dizin sonu (EOCD) imzası: 0x06054b50, dosyanın son 64 KB + 22 baytında aranır.
  var eocd = -1;
  for (var i = data.length - 22; i >= 0 && i >= data.length - 22 - 65535; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return const [];
  final count = bd.getUint16(eocd + 10, Endian.little);
  var p = bd.getUint32(eocd + 16, Endian.little);
  final out = <EmlAttachment>[];
  for (var n = 0; n < count && out.length < max; n++) {
    if (p + 46 > data.length || bd.getUint32(p, Endian.little) != 0x02014b50) break;
    final method = bd.getUint16(p + 10, Endian.little);
    final csize = bd.getUint32(p + 20, Endian.little);
    final usize = bd.getUint32(p + 24, Endian.little);
    final nameLen = bd.getUint16(p + 28, Endian.little);
    final extraLen = bd.getUint16(p + 30, Endian.little);
    final commentLen = bd.getUint16(p + 32, Endian.little);
    final localOff = bd.getUint32(p + 42, Endian.little);
    final fname = latin1.decode(data.sublist(p + 46, p + 46 + nameLen));
    p += 46 + nameLen + extraLen + commentLen;
    if (!fname.toLowerCase().endsWith('.pdf') || usize > _maxAttachmentBytes) continue;
    if (localOff + 30 > data.length || bd.getUint32(localOff, Endian.little) != 0x04034b50) continue;
    final start = localOff + 30 + bd.getUint16(localOff + 26, Endian.little) + bd.getUint16(localOff + 28, Endian.little);
    if (start + csize > data.length) continue;
    final chunk = data.sublist(start, start + csize);
    try {
      final bytes = method == 0
          ? Uint8List.fromList(chunk)
          : method == 8
          ? Uint8List.fromList(ZLibDecoder(raw: true).convert(chunk))
          : null;
      if (bytes != null && bytes.isNotEmpty && bytes.length <= _maxAttachmentBytes) {
        out.add(EmlAttachment(fname.split('/').last, bytes));
      }
    } catch (_) {}
  }
  return out;
}
