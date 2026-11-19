import 'dart:convert';
import 'dart:io';

import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/receipt_parser/parser.dart';
import 'package:flutter_test/flutter_test.dart';

// Ortak altın vektörler (`testdata/parse/*.json`): beklenen değerler Go `Parse` çıktısından üretildi;
// aynı dosyaları `services/expense/golden_parse_test.go` Go'ya karşı doğrular. Para alanları kuruş
// (tamsayı) üzerinden karşılaştırılır. `known_divergence` "dart" içeriyorsa yalnızca `skip` listesindeki
// alanlar atlanır.
final _now = DateTime.utc(2026, 10, 31, 12); // Go testlerindeki `now` ile aynı

int _cents(Object? v) => ((v as num).toDouble() * 100).round();

void main() {
  final files = Directory('../testdata/parse').listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('testdata/parse en az 8 vektör içerir', () => expect(files.length, greaterThanOrEqualTo(8)));

  for (final f in files) {
    final fx = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final name = fx['name'] as String;
    final e = fx['expect'] as Map<String, dynamic>;
    final divergent = ((fx['known_divergence'] as List?) ?? const []).contains('dart');
    final skip = divergent ? ((fx['skip'] as List?) ?? const []).cast<String>().toSet() : <String>{};

    test('golden parse: $name', () {
      final r = parseReceiptText(fx['text'] as String, now: _now);
      if (!skip.contains('merchant')) expect(r.merchant, e['merchant'], reason: 'merchant');
      if (!skip.contains('amount')) {
        expect(r.amount == null ? null : _cents(r.amount), e['amount'] == null ? null : _cents(e['amount']), reason: 'amount');
      }
      if (!skip.contains('date')) expect(r.date, e['date'], reason: 'date');
      if (!skip.contains('needs_review')) expect(r.needsReview, e['needs_review'], reason: 'needs_review');
      if (!skip.contains('discount_total')) expect(_cents(r.discount), _cents(e['discount_total']), reason: 'discount_total');
      if (!skip.contains('item_count')) expect(r.items.length, e['item_count'], reason: 'item_count');
      if (!skip.contains('items')) {
        final want = [for (final i in (e['items'] as List).cast<Map<String, dynamic>>()) (i['name'] as String, _cents(i['amount']))];
        expect([for (final i in r.items) (i.name, _cents(i.amount))], want, reason: 'items');
      }
    });
  }

  test('marka listesi Go sözlüğüyle aynı (testdata/merchant_brands.json)', () {
    final data = jsonDecode(File('../testdata/merchant_brands.json').readAsStringSync()) as Map<String, dynamic>;
    final want = (data['brands'] as List).cast<String>().toList()..sort();
    expect(merchantBrands.toSet().toList()..sort(), want);
  });

  group('kaydedilen tutar (taslak) Go ile aynı', () {
    double saved(String text) =>
        ReceiptDraft.fromParsed(parseReceiptText(text, now: _now).toParsedReceipt(otherCategoryId: 11)).savedAmount;

    test('indirim kalemlere zaten yansımış: 25 kaydedilir (20 değil)', () {
      expect(saved('MARKET\n12.05.2026\nEKMEK 10,00\nSUT 15,00\nINDIRIM -5,00\nTOPLAM 25,00'), 25);
    });

    test('indirim kalemlerden düşülür: 30 - 5 = 25', () {
      expect(saved('MARKET\n12.05.2026\nEKMEK 10,00\nSUT 20,00\nINDIRIM -5,00\nTOPLAM 25,00'), 25);
    });
  });
}
