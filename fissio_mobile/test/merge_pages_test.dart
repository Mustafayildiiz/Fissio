import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:fissio_mobile/ocr/on_device_ocr_engine.dart';
import 'package:fissio_mobile/receipt_parser/merge.dart';
import 'package:flutter_test/flutter_test.dart';

/// `testdata/merge.json`: sunucu (Go `mergePageTexts`) ile aynı vektörler.
void main() {
  final data = jsonDecode(File('../testdata/merge.json').readAsStringSync()) as Map<String, dynamic>;
  final cases = (data['cases'] as List).cast<Map<String, dynamic>>();

  test('yeterli vektör var', () => expect(cases.length, greaterThanOrEqualTo(5)));
  for (final c in cases) {
    test(c['name'] as String, () {
      expect(mergePageTexts((c['pages'] as List).cast<String>()), c['out']);
    });
  }

  test('jaroWinkler Go ile aynı değerler', () {
    expect(jaroWinkler('martha', 'marhta'), closeTo(0.9611, 0.001));
    expect(jaroWinkler('dixon', 'dicksonx'), closeTo(0.8133, 0.001));
    expect(jaroWinkler('abc', 'abc'), 1);
    expect(jaroWinkler('abc', ''), 0);
  });

  test('cihaz içi motor sayfa dikişini birleştirir (çift kalem oluşmaz)', () async {
    final pages = <List<String>>[
      ['MARKET', 'EKMEK 5,00', 'SUT 12,50', 'PEYNIR 30,00'],
      ['SUT 12,50', 'PEYNIR 30,00', 'CAY 20,00', 'TOPLAM 67,50'],
    ];
    var call = 0;
    final engine = OnDeviceOcrEngine(recognizer: _FakeRecognizer((_) {
      final rows = pages[call++];
      return [for (var i = 0; i < rows.length; i++) RecognizedLine(rows[i], Rect.fromLTWH(10, 40.0 * i, 200, 20))];
    }));
    final res = await engine.scan([Uint8List.fromList([1]), Uint8List.fromList([2])]);
    expect(res.ocr.rawText, 'MARKET\nEKMEK 5,00\nSUT 12,50\nPEYNIR 30,00\nCAY 20,00\nTOPLAM 67,50');
  });
}

class _FakeRecognizer implements TextRecognizerPort {
  _FakeRecognizer(this.fn);
  final List<RecognizedLine> Function(Uint8List) fn;
  @override
  Future<List<RecognizedLine>> recognize(Uint8List page) async => fn(page);
}
