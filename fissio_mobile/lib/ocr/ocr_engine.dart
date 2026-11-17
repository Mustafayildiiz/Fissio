import 'dart:typed_data';

import '../api.dart';
import '../models.dart';

class OcrTextBlock {
  final String text;
  final double confidence;
  final List<List<double>>? bbox;

  const OcrTextBlock({required this.text, required this.confidence, this.bbox});

  factory OcrTextBlock.fromJson(Map<String, dynamic> j) => OcrTextBlock(
    text: (j['text'] as String?) ?? '',
    confidence: ((j['confidence'] as num?) ?? 0).toDouble(),
    bbox: (j['bbox'] as List?)
        ?.map((pt) => (pt as List).map((v) => (v as num).toDouble()).toList())
        .toList(),
  );
}

class OcrResult {
  final String rawText;
  final List<OcrTextBlock> blocks;
  final double confidence;
  final String engine;
  final String modelVersion;
  final double elapsedMs;

  const OcrResult({
    required this.rawText,
    this.blocks = const [],
    this.confidence = 0.0,
    this.engine = 'unknown',
    this.modelVersion = 'unknown',
    this.elapsedMs = 0.0,
  });

  bool get isEmpty => rawText.trim().isEmpty;

  factory OcrResult.fromJson(Map<String, dynamic> j) => OcrResult(
    rawText: (j['raw_text'] as String?) ?? '',
    blocks: ((j['blocks'] as List?) ?? [])
        .map((e) => OcrTextBlock.fromJson(e as Map<String, dynamic>))
        .toList(),
    confidence: ((j['confidence'] as num?) ?? 0).toDouble(),
    engine: (j['engine'] as String?) ?? 'paddleocr',
    modelVersion: (j['model_version'] as String?) ?? 'PP-OCRv4-mobile',
    elapsedMs: ((j['elapsed_ms'] as num?) ?? 0).toDouble(),
  );
}

/// OCR + ayrıştırma sonucu (expense `/receipts/scan` yanıtı).
typedef ScanResult = ({OcrResult ocr, ParsedReceipt parsed});

/// Strategy Interface for OCR Engines in the mobile client.
///
/// Motorlar OCR servisine doğrudan gitmez: görsel JWT'li expense servisine
/// (`/receipts/scan`, multipart) gönderilir, seçilen motor adı `engine` olarak iletilir.
abstract class OcrEngine {
  String get engineName;
  String get modelVersion;

  /// Fiş sayfalarını (1..6 fotoğraf) tarar ve ayrıştırır. Implementasyonlar baytları kalıcı saklamamalıdır
  /// (saklama yalnızca fiş kaydedilirken sunucuya yükleme ile yapılır).
  Future<ScanResult> scan(List<Uint8List> pages);
}

/// Concrete OcrEngine strategy backed by PP-OCRv4 Mobile (`PaddleOCR`).
class PaddleOcrEngine implements OcrEngine {
  PaddleOcrEngine({required this.api});

  final ApiClient api;

  @override
  String get engineName => 'paddleocr';

  @override
  String get modelVersion => 'PP-OCRv4-mobile';

  @override
  Future<ScanResult> scan(List<Uint8List> pages) async {
    if (pages.isEmpty || pages.any((p) => p.isEmpty)) {
      throw ApiException('Görsel verisi boş olamaz.');
    }
    return api.scanReceipt(pages, engine: engineName);
  }
}

/// Placeholder / Stub strategy for a future in-house custom OCR model.
class CustomOcrEngine implements OcrEngine {
  CustomOcrEngine({required this.api});

  final ApiClient api;

  @override
  String get engineName => 'custom';

  @override
  String get modelVersion => 'fissio-custom-ocr-v1-stub';

  @override
  Future<ScanResult> scan(List<Uint8List> pages) async {
    if (pages.isEmpty || pages.any((p) => p.isEmpty)) {
      throw ApiException('Görsel verisi boş olamaz.');
    }
    return api.scanReceipt(pages, engine: engineName);
  }
}

/// Sunucu OCR motorunun kullanıcıya gösterilen adı.
String ocrEngineLabel(String e) => e == 'paddleocr' ? 'PP-OCRv4 Mobile' : 'Custom OCR';

typedef OcrEngineBuilder =OcrEngine Function(ApiClient api);

/// Extensible Factory & Provider Registry for runtime OCR engine selection.
class OcrEngineFactory {
  OcrEngineFactory({this.defaultEngine = 'paddleocr'}) {
    register('paddleocr', (api) => PaddleOcrEngine(api: api));
    register('custom', (api) => CustomOcrEngine(api: api));
  }

  String defaultEngine;
  final Map<String, OcrEngineBuilder> _builders = {};

  void register(String name, OcrEngineBuilder builder) {
    _builders[name.trim().toLowerCase()] = builder;
  }

  List<String> get availableEngines => _builders.keys.toList()..sort();

  OcrEngine resolve(ApiClient api, {String? engineName}) {
    final key = (engineName ?? defaultEngine).trim().toLowerCase();
    final builder = _builders[key];
    if (builder == null) {
      throw ArgumentError(
        'Bilinmeyen OCR motoru: $key. Mevcut motorlar: ${availableEngines.join(", ")}',
      );
    }
    return builder(api);
  }
}
