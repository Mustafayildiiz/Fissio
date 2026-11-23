import 'dart:async';
import 'dart:typed_data';

import 'package:fissio_mobile/pages/digital_import.dart';
import 'package:fissio_mobile/pages/receipt_form_page.dart';
import 'package:fissio_mobile/pages/scan_page.dart';
import 'package:fissio_mobile/services/deep_links.dart';
import 'package:fissio_mobile/services/pdf_reader.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// Okumayı [gate] açılana dek bekletir (yavaş PDF).
class _SlowPdfReader implements PdfReader {
  _SlowPdfReader(this.inner, this.gate);
  final PdfReader inner;
  final Future<void> gate;
  @override
  Future<List<String>> readText(String path, {int maxPages = 6}) async {
    await gate;
    return inner.readText(path, maxPages: maxPages);
  }

  @override
  Future<List<Uint8List>> renderPages(String path, {int maxPages = 6}) async {
    await gate;
    return inner.renderPages(path, maxPages: maxPages);
  }
}

Widget _wrap(Widget w) => MaterialApp(theme: buildTheme(brightness: Brightness.light), home: w);

const _invoice = '''
ACME GIDA TICARET A.S.
ETTN: F47AC10B-58CC-4372-A567-0E02B2C3D479
Fatura Tarihi: 05-10-2026
Süt 1 L 2 Adet 30,00 TL 60,00 TL
Ekmek 1 Adet 15,00 TL 15,00 TL
Mal Hizmet Toplam Tutarı 75,00 TL
Hesaplanan KDV (%10) 7,50 TL
Ödenecek Tutar 82,50 TL
''';

void main() {
  late PdfReader saved;
  setUp(() => saved = pdfReader);
  tearDown(() => pdfReader = saved);

  group('Tara sayfasındaki "Dijital Fiş / PDF Ekle"', () {
    testWidgets('düğme görünür; PDF seçilince okunur ve fiş formu taslakla açılır (OCR yok)', (tester) async {
      final reader = FakePdfReader(textPages: [_invoice]);
      pdfReader = reader;
      String? picked;
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(
          ScanPage(
            camera: FakeScanCameraPort(),
            pickPdf: () async => picked = '/tmp/fatura.pdf',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final button = find.byKey(const Key('digital-import-button'));
      expect(button, findsOneWidget);
      expect(find.text('Dijital Fiş / PDF Ekle'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(picked, '/tmp/fatura.pdf');
      expect(reader.paths, ['/tmp/fatura.pdf']);
      expect(find.byType(ReceiptFormPage), findsOneWidget, reason: 'taslak fiş formunda açılır');
    });

    testWidgets('seçici iptal edilirse (null) hiçbir şey olmaz', (tester) async {
      final reader = FakePdfReader(textPages: [_invoice]);
      pdfReader = reader;
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(ScanPage(camera: FakeScanCameraPort(), pickPdf: () async => null)));
      await tester.pump();
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('digital-import-button')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(reader.paths, isEmpty);
      expect(find.byType(ReceiptFormPage), findsNothing);
      expect(find.byType(ScanPage), findsOneWidget);
    });

    testWidgets('okunamayan PDF kullanıcıya iletiyle bildirilir, sayfa açık kalır', (tester) async {
      pdfReader = FakePdfReader(failure: PdfReadException('PDF dosyası açılamadı.'));
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(ScanPage(camera: FakeScanCameraPort(), pickPdf: () async => '/tmp/bozuk.pdf')));
      await tester.pump();
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('digital-import-button')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('açılamadı'), findsOneWidget);
      expect(find.byType(ReceiptFormPage), findsNothing);
    });
  });

  group('ilerleme penceresi', () {
    testWidgets('okuma sürerken üste sayfa açılırsa (ör. fissio://scan) yalnız ilerleme penceresi kaldırılır', (tester) async {
      final gate = Completer<void>();
      pdfReader = _SlowPdfReader(FakePdfReader(failure: PdfReadException('PDF dosyası açılamadı.')), gate.future);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        theme: buildTheme(brightness: Brightness.light),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              key: const ValueKey('import'),
              onPressed: () => runDigitalImport(ctx, path: '/tmp/a.pdf'),
              child: const Text('içe aktar'),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('import')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Araya başka bir sayfa girer (kör pop() önceden BU sayfayı kapatıp spinner'ı bırakırdı).
      nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('ARAYA GİREN'))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('ARAYA GİREN'), findsOneWidget, reason: 'araya giren sayfa kapanmamalı');
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'ilerleme penceresi kalmamalı');
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('derin bağlantı: fissio://import-digital ve paylaşılan PDF', () {
    test('import-digital bekleyen içe aktarma olur, bir kez tüketilir; scan ayrı kalır', () {
      final d = DeepLinkController();
      var notified = 0;
      d.addListener(() => notified++);
      d.handle(Uri.parse(kImportDeepLink));
      expect(d.hasPendingImport, isTrue);
      expect(d.hasPendingScan, isFalse, reason: 'kamera açılmaz');
      expect(d.hasPendingAction, isTrue);
      expect(notified, 1);
      final imp = d.consumeImport();
      expect(imp, isNotNull);
      expect(imp!.path, isNull, reason: 'dosya yok: seçici açılır');
      expect(d.consumeImport(), isNull, reason: 'tek seferlik');
      expect(d.consumeScan(), isFalse);

      d.handle(Uri.parse('fissio://import-digital?homeWidget'));
      expect(d.hasPendingImport, isTrue, reason: 'iOS widget adresi (?homeWidget)');
      d.consumeImport();
      d.handle(Uri.parse('fissio://settings'));
      expect(d.hasPendingAction, isFalse);
    });

    test('paylaşılan PDF dosyası yolu içe aktarma isteğiyle taşınır (soğuk + sıcak açılış)', () async {
      final share = FakeShareIntent(initial: '/cache/shared/a.pdf');
      final d = DeepLinkController();
      await d.init(shareIntent: share);
      expect(d.hasPendingImport, isTrue);
      expect(d.consumeImport()!.path, '/cache/shared/a.pdf');

      share.emit('/cache/shared/b.pdf'); // uygulama açıkken "Paylaş → Fissio"
      await Future<void>.delayed(Duration.zero);
      expect(d.consumeImport()!.path, '/cache/shared/b.pdf');

      d.handleSharedFile('');
      d.handleSharedFile(null);
      expect(d.hasPendingImport, isFalse);
      d.dispose();
    });
  });
}
