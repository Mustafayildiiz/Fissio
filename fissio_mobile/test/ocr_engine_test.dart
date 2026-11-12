import 'dart:typed_data';

import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/ocr/ocr_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePaddleEngine implements OcrEngine {
  @override
  String get engineName => 'paddleocr';

  @override
  String get modelVersion => 'PP-OCRv4-mobile';

  @override
  Future<OcrResult> extractText(Uint8List imageBytes) async {
    return const OcrResult(
      rawText: 'BIM BIRLESIK MAGAZALAR A.S.\nTARIH: 09.11.2026\nTOPLAM 49,50',
      confidence: 0.97,
      engine: 'paddleocr',
      modelVersion: 'PP-OCRv4-mobile',
      elapsedMs: 112.4,
    );
  }
}

void main() {
  test('OcrEngineFactory resolves default PaddleOCR and CustomOCR strategies', () {
    final api = ApiClient();
    final factory = OcrEngineFactory();

    final defaultEngine = factory.resolve(api);
    expect(defaultEngine, isA<PaddleOcrEngine>());
    expect(defaultEngine.engineName, 'paddleocr');
    expect(defaultEngine.modelVersion, 'PP-OCRv4-mobile');

    final customEngine = factory.resolve(api, engineName: 'custom');
    expect(customEngine, isA<CustomOcrEngine>());
    expect(customEngine.engineName, 'custom');

    expect(
      () => factory.resolve(api, engineName: 'unknown'),
      throwsArgumentError,
    );
  });

  test('Custom registered OCR strategy extracts sample receipt text', () async {
    final api = ApiClient();
    final factory = OcrEngineFactory();
    factory.register('paddleocr', (_) => _FakePaddleEngine());

    final engine = factory.resolve(api);
    final sampleBytes = Uint8List.fromList([137, 80, 78, 71]);
    final result = await engine.extractText(sampleBytes);

    expect(result.isEmpty, isFalse);
    expect(result.engine, 'paddleocr');
    expect(result.modelVersion, 'PP-OCRv4-mobile');
    expect(result.rawText, contains('BIM BIRLESIK MAGAZALAR'));
    expect(result.confidence, greaterThan(0.95));
  });
}

