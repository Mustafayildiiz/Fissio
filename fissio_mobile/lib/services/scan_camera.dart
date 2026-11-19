import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:permission_handler/permission_handler.dart' as perm;

import '../ocr/picked_image.dart';
import 'plugin_log.dart';

/// Flaş modu: Kapalı / Otomatik / Sürekli fener.
enum ScanFlash { off, auto, torch }

extension ScanFlashX on ScanFlash {
  String get label => switch (this) {
        ScanFlash.off => 'Kapalı',
        ScanFlash.auto => 'Otomatik',
        ScanFlash.torch => 'Sürekli fener',
      };

  /// Kapalı → Otomatik → Fener → Kapalı.
  ScanFlash get next => ScanFlash.values[(index + 1) % ScanFlash.values.length];
}

enum ScanCameraFailure { permissionDenied, noCamera, unavailable }

class ScanCameraException implements Exception {
  const ScanCameraException(this.kind, [this.detail]);
  final ScanCameraFailure kind;
  final String? detail;

  @override
  String toString() => 'ScanCameraException($kind${detail == null ? '' : ': $detail'})';
}

/// Açık bir kamera oturumu (önizleme + çekim). Donanım bu arayüzün arkasındadır; böylece
/// fiziksel kamerası olmayan testlerde `MissingPluginException` oluşmaz.
abstract class ScanCameraController {
  /// Canlı önizleme (boyut, ebeveyne göre sayfa tarafından `cover` ile kırpılır).
  Widget buildPreview();

  /// Önizlemenin en/boy oranı (genişlik / yükseklik, dikey yönde).
  double get aspectRatio;

  /// Fotoğrafı çeker ve JPEG baytlarını döndürür (geçici dosya silinir).
  Future<Uint8List> capture();

  /// Desteklenmeyen modlar sessizce yutulur.
  Future<void> setFlash(ScanFlash mode);

  /// Dokunarak odaklama: [normalized] önizleme üzerinde 0..1 aralığında bir nokta.
  Future<void> focusAt(Offset normalized);

  Future<void> dispose();
}

abstract class ScanCameraPort {
  /// Kamerayı açar; başarısızlıkta [ScanCameraException] fırlatır (asla başka tür değil).
  Future<ScanCameraController> open();

  /// İzin reddedildiğinde uygulamanın sistem ayarlarını açar.
  Future<void> openSettings();
}

/// Varsayılan kamera portu. Testler `flutter_test_config.dart` içinde sahtesiyle değiştirir; böylece
/// kamera eklentisi olmayan ortamlarda `availableCameras()` hiç çağrılmaz.
ScanCameraPort scanCameraPort = const PluginScanCameraPort();

/// `camera` eklentisi. Eklenti yoksa (test/masaüstü) veya herhangi bir hata olursa
/// [ScanCameraFailure.unavailable] döner; çökme yok.
class PluginScanCameraPort implements ScanCameraPort {
  const PluginScanCameraPort();

  @override
  Future<ScanCameraController> open() async {
    CameraController? controller;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw const ScanCameraException(ScanCameraFailure.noCamera);
      final cam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      // ~1080p JPEG: sunucunun sayfa başına 5 MB sınırının rahat altında, OCR için yeterli.
      controller = CameraController(
        cam,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      await _soft(() => controller!.lockCaptureOrientation(DeviceOrientation.portraitUp));
      await _soft(() => controller!.setFlashMode(FlashMode.off));
      await _soft(() => controller!.setFocusMode(FocusMode.auto));
      return _PluginScanCameraController(controller);
    } on ScanCameraException {
      await _disposeQuietly(controller);
      rethrow;
    } on CameraException catch (e) {
      await _disposeQuietly(controller);
      final denied = e.code.startsWith('CameraAccess') || e.code.contains('Denied') || e.code.contains('Restricted');
      if (!denied) pluginWarn('camera', e);
      throw ScanCameraException(
        denied ? ScanCameraFailure.permissionDenied : ScanCameraFailure.unavailable,
        e.code,
      );
    } catch (e) {
      await _disposeQuietly(controller);
      pluginWarn('camera', e);
      throw ScanCameraException(ScanCameraFailure.unavailable, e.runtimeType.toString());
    }
  }

  @override
  Future<void> openSettings() async {
    try {
      await perm.openAppSettings();
    } catch (e) {
      pluginWarn('openAppSettings', e);
    }
  }
}

Future<void> _soft(Future<void> Function() body) async {
  try {
    await body();
  } catch (_) {
    // Cihaz özelliği desteklemiyor: önizleme yine çalışır.
  }
}

Future<void> _disposeQuietly(CameraController? c) async {
  try {
    await c?.dispose();
  } catch (_) {}
}

class _PluginScanCameraController implements ScanCameraController {
  _PluginScanCameraController(this._c);
  final CameraController _c;

  @override
  Widget buildPreview() => CameraPreview(_c);

  @override
  double get aspectRatio {
    final r = _c.value.aspectRatio;
    // `aspectRatio` yatay (genişlik/yükseklik) bildirilir; dikey kilitli olduğumuzdan çevir.
    return r > 1 ? 1 / r : r;
  }

  @override
  Future<Uint8List> capture() async {
    final shot = await _c.takePicture();
    return readAndDelete(shot.path);
  }

  @override
  Future<void> setFlash(ScanFlash mode) => _soft(
        () => _c.setFlashMode(switch (mode) {
          ScanFlash.off => FlashMode.off,
          ScanFlash.auto => FlashMode.auto,
          ScanFlash.torch => FlashMode.torch,
        }),
      );

  @override
  Future<void> focusAt(Offset normalized) async {
    await _soft(() => _c.setFocusPoint(normalized));
    await _soft(() => _c.setExposurePoint(normalized));
  }

  @override
  Future<void> dispose() => _disposeQuietly(_c);
}
