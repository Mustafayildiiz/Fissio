import 'dart:async';
import 'dart:typed_data';

import 'package:fissio_mobile/pages/receipt_form_page.dart';
import 'package:fissio_mobile/pages/scan_page.dart';
import 'package:fissio_mobile/services/scan_camera.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Widget _wrap(Widget w) => MaterialApp(theme: buildTheme(brightness: Brightness.light), home: w);

/// Sahte kameralı Tara sayfasını açar ve kamera açılışını bekler.
Future<void> _open(
  WidgetTester tester,
  FakeScanCameraPort port, {
  GalleryPicker? gallery,
  List<Uint8List>? initial,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _wrap(ScanPage(camera: port, pickGallery: gallery ?? (_) async => const [], initialPages: initial)),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _shoot(WidgetTester tester, [int n = 1]) async {
  for (var i = 0; i < n; i++) {
    await tester.tap(find.bySemanticsLabel('Fotoğraf çek'));
    await tester.pump();
    await tester.pump();
  }
}

void main() {
  testWidgets('açılışta uygulama içi canlı önizleme ve hizalama kılavuzu görünür', (tester) async {
    final port = FakeScanCameraPort();
    await _open(tester, port);

    expect(port.openCount, 1);
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('guide-frame')), findsOneWidget);
    expect(find.textContaining('Fişi çerçeveye hizalayın'), findsOneWidget);
    expect(find.text('Taramayı başlat'), findsNothing); // henüz sayfa yok
  });

  testWidgets('peş peşe çekim, küçük resim şeridi, silme ve sayfa sınırı', (tester) async {
    final port = FakeScanCameraPort();
    await _open(tester, port);

    await _shoot(tester, 3);
    expect(port.last.captureCount, 3);
    expect(find.text('Sayfa 3/6'), findsOneWidget);
    expect(find.byKey(const ValueKey('thumb-2')), findsOneWidget);
    expect(find.text('Taramayı başlat (3 sayfa)'), findsOneWidget);

    // Ortadaki kareyi sil.
    await tester.tap(find.bySemanticsLabel('Sayfa 2 sil'));
    await tester.pump();
    expect(find.text('Sayfa 2/6'), findsOneWidget);
    expect(find.byKey(const ValueKey('thumb-2')), findsNothing);
    expect(find.text('Taramayı başlat (2 sayfa)'), findsOneWidget);

    // 6 sayfaya kadar çek; fazlası reddedilir.
    await _shoot(tester, 4);
    expect(find.text('Sayfa 6/6'), findsOneWidget);
    final before = port.last.captureCount;
    await tester.tap(find.bySemanticsLabel('Fotoğraf çek'));
    await tester.pump();
    expect(port.last.captureCount, before);
  });

  testWidgets('tek sayfada düğme "Taramayı başlat", çekim hatası çökmez', (tester) async {
    final port = FakeScanCameraPort();
    await _open(tester, port);

    port.last.failNextCapture = true;
    await _shoot(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Fotoğraf çekilemedi. Tekrar deneyin.'), findsOneWidget);
    expect(find.text('Taramayı başlat'), findsNothing);

    await _shoot(tester);
    expect(find.text('Taramayı başlat'), findsOneWidget);
  });

  testWidgets('flaş Kapalı → Otomatik → Sürekli fener → Kapalı döner', (tester) async {
    final port = FakeScanCameraPort();
    await _open(tester, port);

    expect(find.bySemanticsLabel('Flaş: Kapalı'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Flaş: Kapalı'));
    await tester.pump();
    expect(find.bySemanticsLabel('Flaş: Otomatik'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Flaş: Otomatik'));
    await tester.pump();
    expect(find.bySemanticsLabel('Flaş: Sürekli fener'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Flaş: Sürekli fener'));
    await tester.pump();
    expect(find.bySemanticsLabel('Flaş: Kapalı'), findsOneWidget);

    expect(port.last.flashModes, [ScanFlash.auto, ScanFlash.torch, ScanFlash.off]);
  });

  testWidgets('ekrana dokunma, kırpılmış (cover) önizleme koordinatına çevrilerek odaklar', (tester) async {
    final port = FakeScanCameraPort();
    await _open(tester, port);

    final box = tester.getRect(find.byKey(const ValueKey('guide-frame')));
    // Merkeze dokun: kırpma merkezi kaydırmaz.
    await tester.tapAt(box.center);
    await tester.pump();
    expect(port.last.focusPoints, hasLength(1));
    expect(port.last.focusPoints.last.dx, closeTo(.5, .02));
    expect(port.last.focusPoints.last.dy, closeTo(.5, .02));
    expect(find.byKey(const ValueKey('focus-ring')), findsOneWidget);

    // Üst kenara yakın bir noktaya dokun: önizleme 3:4, bu vizör daha dar/uzun → sağ/sol kırpılır,
    // bu yüzden x koordinatı vizör koordinatından belirgin biçimde büyük olmalı.
    final tap = box.topLeft + const Offset(20, 10);
    await tester.tapAt(tap);
    await tester.pump();
    const ph = 1000.0;
    final pw = .75 * ph;
    final scale = [box.width / pw, box.height / ph].reduce((a, b) => a > b ? a : b);
    final ox = (box.width - pw * scale) / 2;
    final oy = (box.height - ph * scale) / 2;
    final p = port.last.focusPoints.last;
    expect(p.dx, closeTo(((20 - ox) / (pw * scale)).clamp(0.0, 1.0), .001));
    expect(p.dy, closeTo(((10 - oy) / (ph * scale)).clamp(0.0, 1.0), .001));
    expect(p.dx, greaterThan(20 / box.width + .02)); // yatay kırpma payı dikkate alınmalı

    await tester.pump(const Duration(seconds: 1)); // halka kaybolur, bekleyen zamanlayıcı kalmaz
    expect(find.byKey(const ValueKey('focus-ring')), findsNothing);
  });

  testWidgets('kamera izni reddedilince yedek ekran: ayarlar, galeri ve manuel yolları', (tester) async {
    final port = FakeScanCameraPort(failure: ScanCameraFailure.permissionDenied);
    final gallery = <int>[];
    await _open(
      tester,
      port,
      gallery: (remaining) async {
        gallery.add(remaining);
        return [Uint8List.fromList([...kOnePixelPng, 1])];
      },
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Kamera izni gerekli'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-preview')), findsNothing);

    await tester.tap(find.text('Ayarlardan izin ver'));
    await tester.pump();
    expect(port.settingsOpened, isTrue);

    // Galeriden seçim yedek ekrandan çalışır (sayfa eklenir, "Taramayı başlat" görünür).
    await tester.tap(find.text('Galeriden seç'));
    await tester.pump();
    await tester.pump();
    expect(gallery, [6]);
    expect(find.textContaining('Taramayı başlat'), findsOneWidget);

    // Manuel giriş formu açılır.
    await tester.tap(find.text('Manuel gir'));
    await tester.pumpAndSettle();
    expect(find.byType(ReceiptFormPage), findsOneWidget);
  });

  testWidgets('izin reddi → ayarlardan dönüş (resumed) kamerayı yeniden dener', (tester) async {
    final port = FakeScanCameraPort(failure: ScanCameraFailure.permissionDenied);
    await _open(tester, port);
    expect(find.text('Kamera izni gerekli'), findsOneWidget);

    await tester.tap(find.text('Ayarlardan izin ver')); // kullanıcı ayarlara gider
    await tester.pump();
    port.failure = null; // ... ve izni verir
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(port.openCount, 2);
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
    expect(find.text('Kamera izni gerekli'), findsNothing);
  });

  testWidgets('izin reddi sonrası ayarlara gitmeden gelen resumed kamerayı yeniden açmaz', (tester) async {
    final port = FakeScanCameraPort(failure: ScanCameraFailure.permissionDenied);
    await _open(tester, port);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(port.openCount, 1); // izin penceresi dönüşünde ikinci kez sorulmaz
    expect(find.text('Kamera izni gerekli'), findsOneWidget);
  });

  testWidgets('kamera açılırken (izin penceresi) inactive → resumed açılışı iptal etmez', (tester) async {
    final gate = Completer<void>();
    final port = FakeScanCameraPort()..gate = gate;
    await _open(tester, port);
    expect(find.byKey(const ValueKey('fake-preview')), findsNothing); // hâlâ açılıyor

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    gate.complete(); // kullanıcı "İzin ver"e bastı
    await tester.pump();
    await tester.pump();

    expect(port.openCount, 1);
    expect(port.last.disposeCount, 0);
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
  });

  testWidgets('kamera açılırken gerçekten arka plana geçilirse açılan kamera bırakılır, dönüşte yeniden açılır', (tester) async {
    final gate = Completer<void>();
    final port = FakeScanCameraPort()..gate = gate;
    await _open(tester, port);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(port.last.disposeCount, 1); // geç gelen kamera sızmaz
    expect(find.byKey(const ValueKey('fake-preview')), findsNothing);

    port.gate = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(port.openCount, 2);
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
  });

  testWidgets('kamera hiç açılamazsa (eklenti yok) çökmeden yedek ekran gösterilir', (tester) async {
    final port = FakeScanCameraPort(failure: ScanCameraFailure.unavailable);
    await _open(tester, port);

    expect(tester.takeException(), isNull);
    expect(find.text('Kamera açılamadı'), findsOneWidget);
    expect(find.text('Ayarlardan izin ver'), findsNothing); // izin sorunu değil
    expect(find.text('Tekrar dene'), findsOneWidget);
    expect(find.text('Manuel gir'), findsOneWidget);
  });

  testWidgets('arka plana alınınca kamera bırakılır, dönünce yeniden açılır; sayfalar korunur', (tester) async {
    final port = FakeScanCameraPort();
    await _open(tester, port);
    await _shoot(tester, 2);
    final first = port.last;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(first.disposeCount, 1);
    expect(find.byKey(const ValueKey('fake-preview')), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(port.openCount, 2);
    expect(port.last, isNot(same(first)));
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
    expect(find.text('Sayfa 2/6'), findsOneWidget); // oturum etkilenmedi
    expect(first.disposeCount, 1); // çift dispose yok
  });

  testWidgets('sayfa kapanınca kamera kaynağı serbest bırakılır', (tester) async {
    final port = FakeScanCameraPort();
    await _open(tester, port);
    final cam = port.last;

    await tester.pumpWidget(_wrap(const SizedBox()));
    await tester.pump();
    expect(cam.disposeCount, 1);
  });

  testWidgets('galeri düğmesi kamera açıkken de çalışır ve oturuma eklenir', (tester) async {
    final port = FakeScanCameraPort();
    await _open(
      tester,
      port,
      gallery: (remaining) async => [
        Uint8List.fromList([...kOnePixelPng, 7]),
        Uint8List.fromList([...kOnePixelPng, 8]),
      ],
    );

    await tester.tap(find.bySemanticsLabel('Galeriden seç (birden fazla)'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Sayfa 2/6'), findsOneWidget);
  });

  testWidgets('Manuel anahtarı kamera ekranında formu açar', (tester) async {
    final port = FakeScanCameraPort();
    await _open(tester, port);
    await tester.tap(find.text('Manuel'));
    await tester.pumpAndSettle();
    expect(find.byType(ReceiptFormPage), findsOneWidget);
  });
}
