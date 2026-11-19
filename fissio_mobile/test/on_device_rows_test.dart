import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:fissio_mobile/ocr/on_device_ocr_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// `testdata/rows.json`: sunucu (Python `_reconstruct_receipt_lines`) ile aynı vektörler.
void main() {
  final data = jsonDecode(File('../testdata/rows.json').readAsStringSync()) as Map<String, dynamic>;
  final cases = (data['cases'] as List).cast<Map<String, dynamic>>();

  RecognizedLine lineOf(Map<String, dynamic> b) {
    final box = [
      for (final p in (b['box'] as List)) Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
    final xs = box.map((p) => p.dx), ys = box.map((p) => p.dy);
    final rect = Rect.fromLTRB(
      xs.reduce((a, b) => a < b ? a : b),
      ys.reduce((a, b) => a < b ? a : b),
      xs.reduce((a, b) => a > b ? a : b),
      ys.reduce((a, b) => a > b ? a : b),
    );
    return RecognizedLine(b['text'] as String, rect, corners: box);
  }

  group('reconstructRows (testdata/rows.json)', () {
    test('yeterli vektör var', () => expect(cases.length, greaterThanOrEqualTo(5)));
    for (final c in cases) {
      test(c['name'] as String, () {
        final lines = [for (final b in (c['blocks'] as List)) lineOf(b as Map<String, dynamic>)];
        expect(reconstructRows(lines), (c['rows'] as List).cast<String>());
      });
    }
  });

  test('köşe noktası yoksa (yalnız Rect) eğim düzeltmesi yapılmaz, düz fişte aynı sonuç', () {
    final c = cases.firstWhere((c) => c['name'] == 'no_tilt');
    final lines = [
      for (final b in (c['blocks'] as List)) RecognizedLine(lineOf(b as Map<String, dynamic>).text, lineOf(b).rect),
    ];
    expect(reconstructRows(lines), (c['rows'] as List).cast<String>());
  });

  test('eğimli fişte köşe yoksa kalem ile tutar kayar (köşe noktası bu yüzden taşınır)', () {
    final c = cases.firstWhere((c) => c['name'] == 'tilt_0_1_label_and_amount_same_row');
    final lines = [
      for (final b in (c['blocks'] as List)) RecognizedLine(lineOf(b as Map<String, dynamic>).text, lineOf(b).rect),
    ];
    expect(reconstructRows(lines), isNot((c['rows'] as List).cast<String>()));
  });
}
