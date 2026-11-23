import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fissio_mobile/receipt_parser/digital_ids.dart';
import 'package:fissio_mobile/receipt_parser/digital_receipt.dart';
import 'package:fissio_mobile/receipt_parser/eml.dart';
import 'package:fissio_mobile/receipt_parser/html_text.dart';
import 'package:flutter_test/flutter_test.dart';

// Dijital fiş ortak altın vektörleri (repo kökü `testdata/`): HTML→metin, "İlet" önsözü, belge/sipariş kimliği, birleştirme kararı
// ve .eml ayrıştırma. Beklenen değerler Go (`services/expense/internal/digital`) çıktısıdır; aynı dosyaları Go testleri okur.

Map<String, dynamic> _json(String rel) => jsonDecode(File('../testdata/$rel').readAsStringSync()) as Map<String, dynamic>;

List<File> _files(String dir) =>
    Directory('../testdata/$dir').listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

String _nl(String s) => s.replaceAll('\r\n', '\n');

MergeDoc _doc(Map<String, dynamic> m) => MergeDoc(
  id: (m['id'] as num).toInt(),
  merchant: m['merchant'] as String,
  amountCents: ((m['amount'] as num).toDouble() * 100).round(),
  date: m['date'] as String,
  documentNo: m['document_no'] as String,
  orderId: m['order_id'] as String,
  items: ((m['items'] as List?) ?? const []).cast<String>(),
);

void main() {
  group('HTML → metin (testdata/html)', () {
    final files = _files('html');
    test('en az 7 vaka', () => expect(files.length, greaterThanOrEqualTo(7)));
    for (final f in files) {
      final v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final e = v['expect'] as Map<String, dynamic>;
      test(v['name'] as String, () {
        final text = stripForwardPreamble(htmlToText(v['html'] as String));
        expect(text, e['text']);
        expect(extractOrderId(text) ?? '', e['order_id']);
        expect(extractDocumentNo(text) ?? '', e['document_no']);
      });
    }
  });

  group('İlet önsözü (testdata/preamble.json)', () {
    final cases = (_json('preamble.json')['cases'] as List).cast<Map<String, dynamic>>();
    test('en az 7 vaka', () => expect(cases.length, greaterThanOrEqualTo(7)));
    for (final c in cases) {
      test(c['name'] as String, () => expect(stripForwardPreamble(c['text'] as String), c['out']));
    }
  });

  group('Belge / sipariş kimliği (testdata/digital_ids.json)', () {
    final cases = (_json('digital_ids.json')['cases'] as List).cast<Map<String, dynamic>>();
    test('en az 15 vaka', () => expect(cases.length, greaterThanOrEqualTo(15)));
    for (final c in cases) {
      test(c['name'] as String, () {
        expect(extractDocumentNo(c['text'] as String) ?? '', c['document_no']);
        expect(extractOrderId(c['text'] as String) ?? '', c['order_id']);
      });
    }
  });

  group('Birleştirme kararı (testdata/merge_decision.json)', () {
    final cases = (_json('merge_decision.json')['cases'] as List).cast<Map<String, dynamic>>();
    test('en az 18 vaka', () => expect(cases.length, greaterThanOrEqualTo(18)));
    for (final c in cases) {
      test(c['name'] as String, () {
        final d = decideMerge(
          _doc(c['incoming'] as Map<String, dynamic>),
          [for (final m in (c['candidates'] as List).cast<Map<String, dynamic>>()) _doc(m)],
        );
        final e = c['expect'] as Map<String, dynamic>;
        expect(d.action, e['action']);
        expect(d.targetId, (e['target_id'] as num).toInt());
      });
    }
  });

  group('EML (testdata/eml)', () {
    final files = _files('eml');
    test('en az 5 vaka', () => expect(files.length, greaterThanOrEqualTo(5)));
    for (final f in files) {
      final v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final e = v['expect'] as Map<String, dynamic>;
      test(v['name'] as String, () {
        final m = parseEml(Uint8List.fromList(utf8.encode(v['eml'] as String)));
        expect(m.subject, e['subject']);
        expect(m.from, e['from']);
        expect(m.messageId, e['message_id']);
        expect(_nl(m.text), e['text']);
        expect(_nl(m.html), e['html']);
        expect([for (final a in m.pdfs) a.name], (e['pdf_names'] as List).cast<String>());
      });
    }
  });

  test('geçersiz / boş girdi', () {
    expect(() => parseEml(Uint8List(0)), throwsA(isA<EmlException>()));
    expect(htmlToText(''), '');
    expect(stripForwardPreamble(''), '');
    expect(extractOrderId(''), isNull);
  });

  test('normalizeOrderId', () {
    expect(normalizeOrderId(' gpa.3345-1234 '), 'GPA.3345-1234');
    expect(normalizeOrderId('ab'), isNull);
    expect(normalizeOrderId('-abc1'), isNull);
  });
}
