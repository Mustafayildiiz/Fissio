import 'dart:typed_data';

import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/ocr/ocr_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePaddleEngine implements OcrEngine {
  @override
  String get engineName => 'paddleocr';

  @override
  String get modelVersion => 'PP-OCRv4-mobile';

  @override
  Future<ScanResult> scan(Uint8List imageBytes) async {
    return (
      ocr: const OcrResult(
        rawText: 'BIM BIRLESIK MAGAZALAR A.S.\nTARIH: 09.11.2026\nTOPLAM 49,50',
        confidence: 0.97,
        engine: 'paddleocr',
        modelVersion: 'PP-OCRv4-mobile',
        elapsedMs: 112.4,
      ),
      parsed: const ParsedReceipt(
        merchant: 'BIM',
        amount: 49.5,
        categoryId: 1,
        categoryName: 'Market',
        needsManual: false,
      ),
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

  test('Registered OCR strategy returns OCR text and parsed fields', () async {
    final api = ApiClient();
    final factory = OcrEngineFactory();
    factory.register('paddleocr', (_) => _FakePaddleEngine());

    final engine = factory.resolve(api);
    final sampleBytes = Uint8List.fromList([137, 80, 78, 71]);
    final scanned = await engine.scan(sampleBytes);
    final result = scanned.ocr;
    expect(scanned.parsed.amount, 49.5);

    expect(result.isEmpty, isFalse);
    expect(result.engine, 'paddleocr');
    expect(result.modelVersion, 'PP-OCRv4-mobile');
    expect(result.rawText, contains('BIM BIRLESIK MAGAZALAR'));
    expect(result.confidence, greaterThan(0.95));
  });
}

