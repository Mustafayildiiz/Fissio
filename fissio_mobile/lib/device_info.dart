import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

typedef DeviceInfo = ({String name, String platform});

/// Cihaz adı/platform bilgisi (Ayarlar > Aktif oturumlar listesi için). Testlerde sahtesi verilir.
abstract class DeviceInfoProvider {
  Future<DeviceInfo> info();
}

class PluginDeviceInfo implements DeviceInfoProvider {
  PluginDeviceInfo();

  DeviceInfo? _cached;

  @override
  Future<DeviceInfo> info() async {
    final c = _cached;
    if (c != null) return c;
    DeviceInfo result = (name: 'Bilinmeyen cihaz', platform: 'unknown');
    try {
      if (kIsWeb) {
        result = (name: 'Web', platform: 'web');
      } else {
        final p = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final a = await p.androidInfo;
          result = (name: '${a.manufacturer} ${a.model}'.trim(), platform: 'android');
        } else if (Platform.isIOS) {
          final i = await p.iosInfo;
          result = (name: i.name, platform: 'ios');
        } else {
          result = (name: Platform.operatingSystem, platform: Platform.operatingSystem);
        }
      }
    } catch (_) {
      // eklenti yoksa (test/masaüstü) genel ad
      result = (name: kIsWeb ? 'Web' : Platform.operatingSystem, platform: kIsWeb ? 'web' : Platform.operatingSystem);
    }
    return _cached = result;
  }
}
