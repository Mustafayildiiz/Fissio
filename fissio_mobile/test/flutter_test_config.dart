import 'dart:async';

import 'package:fissio_mobile/services/scan_camera.dart';

import 'support/fakes.dart';

/// Tüm testler için: gerçek kamera eklentisi yerine "kullanılamıyor" diyen sahte port.
/// (Eklenti olmayan ortamda `availableCameras()` yanıt vermeyip açılış göstergesini sonsuza dek
/// döndürür; `pumpAndSettle` zaman aşımına uğrar.) Kamerayı sınayan testler kendi portunu verir.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  scanCameraPort = FakeScanCameraPort(failure: ScanCameraFailure.unavailable);
  await testMain();
}
