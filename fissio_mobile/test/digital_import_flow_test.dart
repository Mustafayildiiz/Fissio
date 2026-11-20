
import 'package:fissio_mobile/pages/receipt_form_page.dart';
import 'package:fissio_mobile/pages/scan_page.dart';
import 'package:fissio_mobile/services/deep_links.dart';
import 'package:fissio_mobile/services/pdf_reader.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

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
