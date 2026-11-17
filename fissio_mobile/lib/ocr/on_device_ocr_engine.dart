import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import '../receipt_parser/normalize.dart' show fixTurkishGlyphs;
import '../receipt_parser/parser.dart';
import 'ocr_engine.dart';

/// Tanıyıcının döndürdüğü tek bir metin satırı ve görüntüdeki konumu.
class RecognizedLine {
  const RecognizedLine(this.text, this.rect);
  final String text;
  final Rect rect;
}

/// Cihaz içi metin tanıma sınırı: gerçek uygulamada ML Kit, testlerde sahte.
abstract class TextRecognizerPort {
  Future<List<RecognizedLine>> recognize(Uint8List page);
}

/// Google ML Kit (Latin) ile cihaz içinde tanır; ağ gerekmez ve görsel cihazdan çıkmaz.
class MlKitTextRecognizerPort implements TextRecognizerPort {
  @override
  Future<List<RecognizedLine>> recognize(Uint8List page) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}fissio_ocr_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await file.writeAsBytes(page, flush: true);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(file.path));
      return [
        for (final b in result.blocks)
          for (final l in b.lines) RecognizedLine(l.text, l.boundingBox),
      ];
    } finally {
      await recognizer.close();
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

/// ML Kit satırlarını fiş satırlarına dizer: dikey merkezleri aynı hizada olan parçalar (kalem adı solda,
/// tutar sağda) tek satırda soldan sağa birleşir. Sunucu OCR'ının `_reconstruct_receipt_lines` işine denk.
List<String> reconstructRows(List<RecognizedLine> lines) {
  final items = lines.where((l) => l.text.trim().isNotEmpty).toList();
  if (items.isEmpty) return [];
  items.sort((a, b) => a.rect.center.dy.compareTo(b.rect.center.dy));
  final heights = items.map((l) => l.rect.height).toList()..sort();
  final median = heights[heights.length ~/ 2];
  final tol = (median <= 0 ? 10.0 : median) * 0.6;

  final rows = <List<RecognizedLine>>[];
  for (final l in items) {
    if (rows.isNotEmpty) {
      final row = rows.last;
      final cy = row.map((e) => e.rect.center.dy).reduce((a, b) => a + b) / row.length;
      if ((l.rect.center.dy - cy).abs() <= tol) {
        row.add(l);
        continue;
      }
    }
    rows.add([l]);
  }
  return [
    for (final row in rows)
      (row..sort((a, b) => a.rect.left.compareTo(b.rect.left))).map((e) => e.text.trim()).join(' '),
  ];
}

/// Cihaz içi OCR + çevrimdışı ayrıştırma. Sunucuya hiçbir istek atmaz.
///
/// Çok sayfalı fişte sayfa metinleri art arda eklenir (sunucudaki dikiş birleştirme yapılmaz); örtüşen
/// satırlar mükerrer kalem üretirse kullanıcı formda siler.
class OnDeviceOcrEngine implements OcrEngine {
  OnDeviceOcrEngine({TextRecognizerPort? recognizer, this.otherCategoryId, DateTime Function()? clock})
    : _recognizer = recognizer ?? MlKitTextRecognizerPort(),
      _clock = clock ?? DateTime.now;

  final TextRecognizerPort _recognizer;
  final DateTime Function() _clock;

  /// `Diğer` kategorisinin kimliği (kategori motoru çevrimdışıyken kullanılmaz); bilinmiyorsa null.
  final int? Function()? otherCategoryId;

  static const name = 'ondevice';

  @override
  String get engineName => name;

  @override
  String get modelVersion => 'mlkit-text-recognition-latin';

  @override
  Future<ScanResult> scan(List<Uint8List> pages) async {
    if (pages.isEmpty || pages.any((p) => p.isEmpty)) {
      throw ApiException('Görsel verisi boş olamaz.');
    }
    final sw = Stopwatch()..start();
    final texts = <String>[];
    final blocks = <OcrTextBlock>[];
    try {
      for (final page in pages) {
        // Ham metin de normalize edilir ($ → Ş/ş; fiyat işaretleri korunur): form ve ayrıştırıcı aynı metni görür.
        final rows = reconstructRows(await _recognizer.recognize(page)).map(fixTurkishGlyphs).toList();
        texts.add(rows.join('\n'));
        blocks.addAll([for (final r in rows) OcrTextBlock(text: r, confidence: 0)]);
      }
    } catch (_) {
      // ML Kit/PlatformException, eksik eklenti (masaüstü/simülatör), geçici dosya hatası: tarama ekranı yalnızca
      // ApiException gösterir; ağ hatası olmadığı için sunucuya düşülmez, kullanıcı mesajı görür.
      throw ApiException('Fiş cihazda okunamadı. Fotoğrafı yeniden çekmeyi ya da bilgileri elle girmeyi deneyin.');
    }
    final raw = texts.where((t) => t.isNotEmpty).join('\n');
    final ocr = OcrResult(
      rawText: raw,
      blocks: blocks,
      engine: engineName,
      modelVersion: modelVersion,
      elapsedMs: sw.elapsedMilliseconds.toDouble(),
    );
    final parsed = parseReceiptText(raw, now: _clock()).toParsedReceipt(otherCategoryId: otherCategoryId?.call());
    return (ocr: ocr, parsed: parsed);
  }
}
