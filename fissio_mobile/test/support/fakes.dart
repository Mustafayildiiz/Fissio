import 'dart:async';
import 'dart:typed_data';

import 'package:fissio_mobile/services/launcher_icon.dart';
import 'package:fissio_mobile/services/pdf_reader.dart';
import 'package:fissio_mobile/services/share_intent.dart';
import 'package:fissio_mobile/services/scan_camera.dart';
import 'package:fissio_mobile/services/notifier.dart';
import 'package:fissio_mobile/services/widget_sync.dart';
import 'package:flutter/material.dart';

/// Gösterilen / planlanan yerel bildirimleri kaydeden sahte bildirim servisi.
class FakeNotifier implements LocalNotifier {
  final shown = <({int id, String title, String body})>[];
  final scheduled = <int, ({DateTime when, String title, String body})>{};
  int cancelScheduledCalls = 0;
  int cancelAllCalls = 0;
  int permissionRequests = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<void> show({required int id, required String title, required String body, String? payload}) async {
    shown.add((id: id, title: title, body: body));
  }

  @override
  Future<void> schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
    String? payload,
  }) async {
    scheduled[id] = (when: when, title: title, body: body);
  }

  @override
  Future<void> cancelScheduled() async {
    cancelScheduledCalls++;
    scheduled.clear();
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
    scheduled.clear();
    shown.clear();
  }
}

/// Ana ekran widget'ına yazılan her veriyi kaydeder (null = temizlendi).
class FakeWidgetSync implements WidgetSync {
  final updates = <WidgetPayload?>[];
  WidgetPayload? get last => updates.isEmpty ? null : updates.last;

  @override
  Future<void> update(WidgetPayload? payload) async => updates.add(payload);

  /// `updateTheme` çağrıları: (tema adı, marka rengi ARGB).
  final themes = <(String, int)>[];
  @override
  Future<void> updateTheme(String theme, int accentArgb) async => themes.add((theme, accentArgb));
}

/// PDF okuyucu sahtesi: [textPages] metin katmanı, [pageImages] taranmış PDF'in sayfa görselleri; [failure] ile hata.
class FakePdfReader implements PdfReader {
  FakePdfReader({this.textPages = const [], this.pageImages = const [], this.failure});
  List<String> textPages;
  List<Uint8List> pageImages;
  PdfReadException? failure;
  final paths = <String>[];
  int renderCalls = 0;

  @override
  Future<List<String>> readText(String path, {int maxPages = 6}) async {
    paths.add(path);
    if (failure != null) throw failure!;
    return textPages;
  }

  @override
  Future<List<Uint8List>> renderPages(String path, {int maxPages = 6}) async {
    renderCalls++;
    if (failure != null) throw failure!;
    return pageImages;
  }
}

/// Paylaşım köprüsü sahtesi: [initial] soğuk açılış dosyası, [emit] ile sıcak açılış.
class FakeShareIntent implements ShareIntentPort {
  FakeShareIntent({this.initial});
  String? initial;
  final _c = StreamController<String>.broadcast();
  @override
  Future<String?> initialFile() async => initial;
  @override
  Stream<String> get files => _c.stream;
  void emit(String path) => _c.add(path);
}

class FakeLauncherIcon implements LauncherIcon {
  FakeLauncherIcon({this.isSupported = true});
  final bool isSupported;
  final applied = <String>[];

  @override
  Future<bool> get supported async => isSupported;

  @override
  Future<bool> set(String key) async {
    applied.add(key);
    return true;
  }
}

/// Fiziksel kamera olmadan uygulama içi kamerayı sınar: sonuç yapılandırılır, çağrılar kaydedilir.
class FakeScanCameraPort implements ScanCameraPort {
  FakeScanCameraPort({this.failure});

  /// null = kamera açılır; aksi halde `open()` bu nedenle [ScanCameraException] fırlatır.
  ScanCameraFailure? failure;
  /// Verilirse `open()` tamamlanana kadar bekler (açılış sürerken yaşam döngüsü olaylarını sınamak için).
  Completer<void>? gate;
  int openCount = 0;
  bool settingsOpened = false;
  final controllers = <FakeScanCameraController>[];

  FakeScanCameraController get last => controllers.last;

  @override
  Future<ScanCameraController> open() async {
    openCount++;
    await gate?.future;
    final f = failure;
    if (f != null) throw ScanCameraException(f);
    final c = FakeScanCameraController();
    controllers.add(c);
    return c;
  }

  @override
  Future<void> openSettings() async {
    settingsOpened = true;
  }
}

class FakeScanCameraController implements ScanCameraController {
  int disposeCount = 0;
  int captureCount = 0;
  bool failNextCapture = false;
  final flashModes = <ScanFlash>[];
  final focusPoints = <Offset>[];

  @override
  double get aspectRatio => 3 / 4;

  @override
  Widget buildPreview() => const ColoredBox(key: ValueKey('fake-preview'), color: Color(0xFF334455));

  @override
  Future<Uint8List> capture() async {
    if (failNextCapture) {
      failNextCapture = false;
      throw StateError('capture failed');
    }
    captureCount++;
    // Her çekim farklı bayt dizisi (küçük resim anahtarları ve sıralama için).
    return Uint8List.fromList([...kOnePixelPng, captureCount]);
  }

  @override
  Future<void> setFlash(ScanFlash mode) async => flashModes.add(mode);

  @override
  Future<void> focusAt(Offset normalized) async => focusPoints.add(normalized);

  @override
  Future<void> dispose() async => disposeCount++;
}

/// 1x1 geçerli PNG; sonuna ek bayt eklenerek ayırt edilebilir kareler üretilir (dosya sonundan sonrası yok sayılır).
const kOnePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
  0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
  0x44, 0xAE, 0x42, 0x60, 0x82,
];
