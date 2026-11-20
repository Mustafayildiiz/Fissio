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

  /// Motor bilgisi (sunucu: `rec_*` model/sözlük, eksik harfler); cihaz içi OCR'da boş.
  final Map<String, dynamic> metadata;

  /// Çok sayfalı taramada sayfa sırasına göre ham metinler (okunamayan sayfa boş) ve okunamayan sayfaların 1 tabanlı
  /// numaraları: yalnız başarısız sayfalar yeniden taranıp metinler sırayla birleştirilebilsin diye.
  final List<String> pageTexts;
  final List<int> failedPages;

  const OcrResult({
    required this.rawText,
    this.blocks = const [],
    this.confidence = 0.0,
    this.engine = 'unknown',
    this.modelVersion = 'unknown',
    this.elapsedMs = 0.0,
    this.metadata = const {},
    this.pageTexts = const [],
    this.failedPages = const [],
  });

  bool get isEmpty => rawText.trim().isEmpty;

  OcrResult withFailedPages(List<int> failed) => copyWith(failedPages: failed);

  OcrResult copyWith({String? rawText, List<String>? pageTexts, List<int>? failedPages, String? engine}) => OcrResult(
    rawText: rawText ?? this.rawText,
    blocks: blocks,
    confidence: confidence,
    engine: engine ?? this.engine,
    modelVersion: modelVersion,
    elapsedMs: elapsedMs,
    metadata: metadata,
    pageTexts: pageTexts ?? this.pageTexts,
    failedPages: failedPages ?? this.failedPages,
  );

  factory OcrResult.fromJson(Map<String, dynamic> j) => OcrResult(
    rawText: (j['raw_text'] as String?) ?? '',
    blocks: ((j['blocks'] as List?) ?? [])
        .map((e) => OcrTextBlock.fromJson(e as Map<String, dynamic>))
        .toList(),
    confidence: ((j['confidence'] as num?) ?? 0).toDouble(),
    engine: (j['engine'] as String?) ?? 'paddleocr',
    modelVersion: (j['model_version'] as String?) ?? 'PP-OCRv4-mobile',
    elapsedMs: ((j['elapsed_ms'] as num?) ?? 0).toDouble(),
    metadata: (j['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
    pageTexts: ((j['page_texts'] as List?) ?? const []).map((e) => '$e').toList(),
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

/// Cihaz içi (Google ML Kit) motorunun fişte saklanan kimliği. Motorun kod adı `ondevice`'tır
/// ([OnDeviceOcrEngine.name]); saklanan değer kullanıcıya/sunucuya anlamlı `mlkit`'tir.
const kStoredMlKit = 'mlkit';

/// Metin katmanlı dijital fiş / e-fatura PDF'inin ayrıştırıcısı (OCR yok; metin doğrudan okunur).
const kStoredPdf = 'pdf';

/// Tarama sonucundaki motor adını ([OcrResult.engine]) fişe yazılacak kimliğe çevirir
/// (`ondevice` → `mlkit`, `paddleocr`/`custom` aynen); bilinmeyen/`unknown` null döner.
String? storedOcrEngineId(String? engine) {
  switch (engine?.trim().toLowerCase()) {
    case 'ondevice':
    case kStoredMlKit:
      return kStoredMlKit;
    case kStoredPdf:
      return kStoredPdf;
    case 'paddleocr':
      return 'paddleocr';
    case 'custom':
      return 'custom';
    default:
      return null;
  }
}

/// Fiş detayında gösterilen motor adı; bilinmiyorsa (manuel/eski kayıt) null.
String? ocrEngineDisplayName(String? stored) => switch (stored) {
  'paddleocr' => 'PaddleOCR',
  'custom' => 'Custom OCR',
  kStoredMlKit => 'Google ML Kit',
  kStoredPdf => 'PDF / E-Fatura Ayrıştırıcı',
  _ => null,
};

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
