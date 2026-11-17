import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/ocr/on_device_ocr_engine.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// ML Kit yerine sahte tanıyıcı: fiş parçalarını (ad solda, tutar sağda ayrı) karışık sırada verir.
class _FakeRecognizer implements TextRecognizerPort {
  int calls = 0;
  @override
  Future<List<RecognizedLine>> recognize(Uint8List page) async {
    calls++;
    RecognizedLine l(String t, double x, double y) => RecognizedLine(t, Rect.fromLTWH(x, y, 100, 20));
    return [
      l(r'KA$AR', 10, 100),
      l('12,50', 300, 102),
      l('TOPLAM', 10, 140),
      l('MARKET', 10, 10),
      l('12.05.2026', 10, 60),
      l('17,50', 300, 141),
      l('EKMEK', 10, 120),
      l('5,00', 300, 121),
    ];
  }
}

class _ThrowingRecognizer implements TextRecognizerPort {
  @override
  Future<List<RecognizedLine>> recognize(Uint8List page) async =>
      throw PlatformException(code: 'mlkit', message: 'boom');
}

final _pages =[Uint8List.fromList([1, 2, 3])];

void main() {
  late FakeBackend backend;
  late _FakeRecognizer recognizer;
  var mode = OcrMode.auto;

  Harness harness() {
    backend = FakeBackend();
    recognizer = _FakeRecognizer();
    return Harness(
      backend: backend,
      onDeviceOcr: OnDeviceOcrEngine(recognizer: recognizer, clock: () => DateTime.utc(2026, 10, 31)),
      ocrMode: () => mode,
    );
  }

  setUp(() => mode = OcrMode.auto);

  test('cihaz içi motor: satırları dizer, glif düzeltir, kalemleri ayrıştırır, sunucuya istek atmaz', () async {
    final h = harness();
    final r = await OnDeviceOcrEngine(recognizer: recognizer, clock: () => DateTime.utc(2026, 10, 31)).scan(_pages);
    expect(r.ocr.engine, 'ondevice');
    expect(r.ocr.rawText.split('\n'), ['MARKET', '12.05.2026', 'KAŞAR 12,50', 'EKMEK 5,00', 'TOPLAM 17,50']);
    expect(r.parsed.merchant, 'MARKET');
    expect(r.parsed.amount, 17.5);
    expect(r.parsed.date, DateTime(2026, 5, 12));
    expect(r.parsed.items.map((i) => (i.name, i.amount)), [('KAŞAR', 12.5), ('EKMEK', 5.0)]);
    expect(r.parsed.categoryNeedsReview, isTrue);
    expect(backend.scanCalls, 0);
    expect(h.backend.log, isEmpty);
  });

  test('boş sayfa hata verir', () async {
    final e = OnDeviceOcrEngine(recognizer: _FakeRecognizer());
    await expectLater(e.scan([Uint8List(0)]), throwsA(isA<ApiException>()));
  });

  test('auto + senkron açık + çevrimiçi: sunucu OCR', () async {
    final h = harness();
    await h.signIn('ali@x.co');
    final r = await h.app.scanAndParseReceipt(_pages);
    expect(r.ocr.engine, 'paddleocr');
    expect(backend.scanCalls, 1);
    expect(recognizer.calls, 0);
  });

  test('auto + bağlantı yok: hata vermeden cihaz içi OCR, sunucuya istek yok', () async {
    final h = harness();
    await h.signIn('ali@x.co');
    h.connectivity.online = false;
    final before = backend.scanCalls;
    final r = await h.app.scanAndParseReceipt(_pages);
    expect(r.ocr.engine, 'ondevice');
    expect(backend.scanCalls, before);
    expect(r.parsed.items, isNotEmpty);
  });

  test('auto + bulut senkronu kapalı: cihaz içi OCR (internet olsa bile)', () async {
    final h = harness();
    await h.signIn('ali@x.co');
    await h.app.setSyncEnabled(false);
    final r = await h.app.scanAndParseReceipt(_pages);
    expect(r.ocr.engine, 'ondevice');
    expect(backend.scanCalls, 0);
  });

  test('onDevice tercihi her zaman cihaz içi; server tercihi sunucu', () async {
    final h = harness();
    await h.signIn('ali@x.co');
    mode = OcrMode.onDevice;
    expect((await h.app.scanAndParseReceipt(_pages)).ocr.engine, 'ondevice');
    expect(backend.scanCalls, 0);
    mode = OcrMode.server;
    expect((await h.app.scanAndParseReceipt(_pages)).ocr.engine, 'paddleocr');
    expect(backend.scanCalls, 1);
    // Senkron kapalıyken "Sunucu" seçili olsa bile fotoğraf sunucuya gitmez.
    await h.app.setSyncEnabled(false);
    expect((await h.app.scanAndParseReceipt(_pages)).ocr.engine, 'ondevice');
    expect(backend.scanCalls, 1);
  });

  test('tanıyıcı hatası (PlatformException vb.) ApiException olur; sunucuya düşülmez', () async {
    final h = harness();
    await h.signIn('ali@x.co');
    mode = OcrMode.onDevice;
    final app = Harness(
      backend: backend,
      onDeviceOcr: OnDeviceOcrEngine(recognizer: _ThrowingRecognizer()),
      ocrMode: () => mode,
    );
    await app.signIn('veli@x.co');
    final before = backend.scanCalls;
    await expectLater(
      app.app.scanAndParseReceipt(_pages),
      throwsA(isA<ApiException>().having((e) => e.network, 'network', isFalse)),
    );
    expect(backend.scanCalls, before);
  });

  test('sunucu OCR ağ hatası verirse cihaz içine düşer; ağ dışı hata iletilir', () async {
    final h = harness();
    await h.signIn('ali@x.co');
    backend.offline = true; // bağlantı var görünür ama sunucuya ulaşılamıyor
    final r = await h.app.scanAndParseReceipt(_pages);
    expect(r.ocr.engine, 'ondevice');

    backend.offline = false;
    backend.failPaths.add('POST /receipts/scan');
    await expectLater(h.app.scanAndParseReceipt(_pages), throwsA(isA<ApiException>()));
  });

  test('çevrimdışı okunan fiş yerel kuyruğa kaydedilir ve bağlantı gelince yüklenir', () async {
    final h = harness();
    await h.signIn('ali@x.co');
    h.connectivity.online = false;
    backend.offline = true;
    final scan = await h.app.scanAndParseReceipt(_pages);
    final res = await h.app.saveDraft(ReceiptDraft.fromParsed(scan.parsed));
    expect(res.queued, isTrue);
    expect(h.app.pendingCount, 1);
    backend.offline = false;
    h.connectivity.online = true;
    await h.app.flushNow(force: true);
    expect(h.app.pendingCount, 0);
    expect(backend.expensesOf('ali@x.co').length, 1);
  });

  test('OcrMode tercihi kalıcıdır', () async {
    final store = MemPrefs();
    await ThemeController(store: store).setOcrMode(OcrMode.onDevice);
    final b = ThemeController(store: store);
    await b.load();
    expect(b.ocrMode, OcrMode.onDevice);
    expect(ThemeController(store: MemPrefs()).ocrMode, OcrMode.auto);
  });
}
