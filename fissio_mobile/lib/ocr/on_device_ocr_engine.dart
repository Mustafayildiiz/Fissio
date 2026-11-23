import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import '../receipt_parser/normalize.dart' show fixTurkishGlyphs;
import '../receipt_parser/merge.dart';
import '../receipt_parser/parser.dart';
import 'ocr_engine.dart';

/// Tanıyıcının döndürdüğü tek bir metin satırı ve görüntüdeki konumu.
class RecognizedLine {
  const RecognizedLine(this.text, this.rect, {this.corners});
  final String text;
  final Rect rect;

  /// Döndürülmüş köşe noktaları (sol-üst, sağ-üst, sağ-alt, sol-alt); yoksa satır eğimi tahmin edilemez.
  final List<Offset>? corners;
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
          for (final l in b.lines)
            RecognizedLine(
              l.text,
              l.boundingBox,
              corners: l.cornerPoints.length >= 4
                  ? [for (final p in l.cornerPoints) Offset(p.x.toDouble(), p.y.toDouble())]
                  : null,
            ),
      ];
    } finally {
      await recognizer.close();
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

/// Dikey konuma göre değişen satır eğimi s(y) (Python `postprocess.local_slope_fn`'in aynısı; ortak vektörler
/// `testdata/rows.json`). Kağıt eğik/kıvrıksa eğim sayfa boyunca değişir: her konum için en yakın [neighbors] uzun
/// satırın (genişlik >= 2 x yükseklik) üst kenar eğiminin ortancası kullanılır. Yeterli örnek yoksa 0.
double Function(double) localSlopeFn(List<RecognizedLine> lines, {double maxSlope = 0.3, int neighbors = 7}) {
  final samples = <({double y, double slope})>[];
  for (final l in lines) {
    final c = l.corners;
    if (c == null || c.length < 4) continue;
    final x0 = c[0].dx, y0 = c[0].dy, x1 = c[1].dx, y1 = c[1].dy;
    final ys = c.map((p) => p.dy);
    final minY = ys.reduce((a, b) => a < b ? a : b), maxY = ys.reduce((a, b) => a > b ? a : b);
    final height = (maxY - minY) < 1.0 ? 1.0 : (maxY - minY);
    if ((x1 - x0).abs() < 2 * height) continue;
    samples.add((y: (minY + maxY) / 2.0, slope: (y1 - y0) / (x1 - x0)));
  }
  if (samples.length < 3) return (_) => 0.0;
  samples.sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.slope.compareTo(b.slope));

  return (double y) {
    // Python sorted() kararlıdır; Dart sort() değil: eşit uzaklıkta özgün sıra korunur.
    final order = List<int>.generate(samples.length, (i) => i)
      ..sort((i, j) {
        final c = (samples[i].y - y).abs().compareTo((samples[j].y - y).abs());
        return c != 0 ? c : i.compareTo(j);
      });
    final near = [for (final i in order.take(neighbors)) samples[i].slope]..sort();
    final n = near.length;
    final median = n.isOdd ? near[n ~/ 2] : (near[n ~/ 2 - 1] + near[n ~/ 2]) / 2.0;
    return median < -maxSlope ? -maxSlope : (median > maxSlope ? maxSlope : median);
  };
}

/// Satır grubu girdisi (Python `postprocess.RowEntry`): satır, eğim düzeltmeli y, x_min, yükseklik, x merkezi,
/// ham y merkezi ve kararlı sıralama için özgün sıra.
typedef _RowEntry = ({RecognizedLine line, double y, double x, double h, double xc, double yRaw, int i});

/// Python `postprocess.group_receipt_rows`'un aynısı: y_adj = y - s(y)·x ile eğim düzeltilir, (y_adj, x_min)
/// sırasına dizilir ve satırın ortalama y'sine yeterince yakın (eşik = max(8, 0.55 x ort. yükseklik)) parçalar aynı
/// satıra eklenir.
List<List<_RowEntry>> _groupRows(List<RecognizedLine> items, double Function(double) slopeAt) {
  final entries = <_RowEntry>[];
  for (var i = 0; i < items.length; i++) {
    final l = items[i];
    final c = l.corners;
    final double minX, maxX, minY, maxY;
    if (c != null && c.length >= 4) {
      minX = c.map((p) => p.dx).reduce((a, b) => a < b ? a : b);
      maxX = c.map((p) => p.dx).reduce((a, b) => a > b ? a : b);
      minY = c.map((p) => p.dy).reduce((a, b) => a < b ? a : b);
      maxY = c.map((p) => p.dy).reduce((a, b) => a > b ? a : b);
    } else {
      minX = l.rect.left;
      maxX = l.rect.right;
      minY = l.rect.top;
      maxY = l.rect.bottom;
    }
    final yRaw = (minY + maxY) / 2.0;
    final xc = (minX + maxX) / 2.0;
    entries.add((
      line: l,
      y: yRaw - slopeAt(yRaw) * xc,
      x: minX,
      h: (maxY - minY) < 1.0 ? 1.0 : (maxY - minY),
      xc: xc,
      yRaw: yRaw,
      i: i,
    ));
  }
  // Python: sort(key=(y_center, x_min)) kararlı → eşitlikte özgün sıra.
  entries.sort((a, b) {
    var c = a.y.compareTo(b.y);
    if (c == 0) c = a.x.compareTo(b.x);
    return c != 0 ? c : a.i.compareTo(b.i);
  });

  final rows = <List<_RowEntry>>[];
  for (final e in entries) {
    if (rows.isNotEmpty) {
      final row = rows.last;
      final avgY = row.fold<double>(0, (s, r) => s + r.y) / row.length;
      final avgH = row.fold<double>(0, (s, r) => s + r.h) / row.length;
      final threshold = (avgH * 0.55) < 8.0 ? 8.0 : avgH * 0.55;
      if ((e.y - avgY).abs() <= threshold) {
        row.add(e);
        continue;
      }
    }
    rows.add([e]);
  }
  return rows;
}

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
}

/// Python `postprocess.refine_slope_fn`'in aynısı: eğimi satır ÇİFTLERİNDEN (en sol ad - en sağ tutar, aralarında
/// >= [minSpan] x yükseklik) yeniden kestirir; konuma göre en yakın [neighbors] ölçümün ortancası. Kıvrık fişte tek
/// kutunun üst kenar eğimi gerçek satır eğimini hafife alır ve sağ sütun bir satır kayar. >= 3 geniş satır yoksa
/// [base] aynen döner.
double Function(double) refineSlopeFn(
  List<RecognizedLine> items,
  double Function(double) base, {
  int iterations = 2,
  int neighbors = 7,
  double maxSlope = 0.3,
  double minSpan = 8.0,
}) {
  var fn = base;
  for (var it = 0; it < iterations; it++) {
    final samples = <({double y, double slope})>[];
    for (final row in _groupRows(items, fn)) {
      if (row.length < 2) continue;
      // Python sorted(key=x_center) kararlı: eşit x merkezinde özgün sıra.
      final ordered = [...row]..sort((a, b) {
          final c = a.xc.compareTo(b.xc);
          return c != 0 ? c : a.i.compareTo(b.i);
        });
      final left = ordered.first, right = ordered.last;
      final height = _median([for (final e in row) e.h]);
      final dx = right.xc - left.xc;
      if (dx < minSpan * height) continue;
      final slope = (right.yRaw - left.yRaw) / dx;
      if (slope.abs() <= maxSlope) samples.add((y: (left.yRaw + right.yRaw) / 2.0, slope: slope));
    }
    if (samples.length < 3) break;
    samples.sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.slope.compareTo(b.slope));
    final pts = samples;
    fn = (double y) {
      final order = List<int>.generate(pts.length, (i) => i)
        ..sort((i, j) {
          final c = (pts[i].y - y).abs().compareTo((pts[j].y - y).abs());
          return c != 0 ? c : i.compareTo(j);
        });
      return _median([for (final i in order.take(neighbors)) pts[i].slope]);
    };
  }
  return fn;
}

/// ML Kit satırlarını fiş satırlarına dizer: aynı hizadaki parçalar (kalem adı solda, tutar sağda) tek satırda
/// soldan sağa birleşir. Sunucudaki `PaddleOcrEngine._reconstruct_receipt_lines`'in aynısıdır (ortak vektörler
/// `testdata/rows.json`): satır merkezi yerel eğimle düzeltilir (y_adj = y - s(y)·x; eğim önce kutu kenarlarından,
/// sonra satır çiftlerinden kestirilir), satır toleransı satırın ortalama yüksekliğine göre belirlenir (en az 8 px).
List<String> reconstructRows(List<RecognizedLine> lines) {
  final items = lines.where((l) => l.text.trim().isNotEmpty).toList();
  if (items.isEmpty) return [];
  final slopeAt = refineSlopeFn(items, localSlopeFn(items));
  final rows = _groupRows(items, slopeAt);
  return [
    for (final row in rows)
      (row..sort((a, b) {
            final c = a.x.compareTo(b.x);
            return c != 0 ? c : a.i.compareTo(b.i);
          }))
          .map((e) => e.line.text.trim())
          .join(' '),
  ];
}

/// Cihaz içi OCR + çevrimdışı ayrıştırma. Sunucuya hiçbir istek atmaz.
///
/// Çok sayfalı fişte sayfa metinleri dikiş birleştirmeyle (`mergePageTexts`, sunucuyla aynı) tek metne iner.
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
    // Sayfa dikişlerindeki çakışan satırlar sunucudaki gibi (en az 2 ardışık satır) birleştirilir.
    final raw = mergePageTexts(texts);
    final ocr = OcrResult(
      rawText: raw,
      blocks: blocks,
      engine: engineName,
      modelVersion: modelVersion,
      elapsedMs: sw.elapsedMilliseconds.toDouble(),
      pageTexts: texts,
    );
    final parsed = parseReceiptText(raw, now: _clock()).toParsedReceipt(otherCategoryId: otherCategoryId?.call());
    return (ocr: ocr, parsed: parsed);
  }
}
