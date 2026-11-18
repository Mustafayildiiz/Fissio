import 'package:flutter/services.dart';

import 'plugin_log.dart';

/// Uygulama başlatıcı (launcher) ikonunu değiştirir. Renk anahtarları [kBrandPalette] ile aynıdır
/// ('ink', 'graphite', 'red', 'purple', 'green', 'darkred', 'blue').
///
/// Android: her renk için bir `activity-alias`; seçilen etkinleştirilir, diğerleri devre dışı bırakılır.
/// iOS: `UIApplication.setAlternateIconName` (Info.plist `CFBundleAlternateIcons`). 'red' varsayılan ikondur.
abstract class LauncherIcon {
  /// Platform değiştirmeyi destekliyor mu (masaüstü/test: false).
  Future<bool> get supported;
  Future<bool> set(String key);
}

class NoopLauncherIcon implements LauncherIcon {
  const NoopLauncherIcon();
  @override
  Future<bool> get supported async => false;
  @override
  Future<bool> set(String key) async => false;
}

class ChannelLauncherIcon implements LauncherIcon {
  const ChannelLauncherIcon();
  static const _channel = MethodChannel('fissio/launcher_icon');

  @override
  Future<bool> get supported async {
    try {
      return await _channel.invokeMethod<bool>('supported') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> set(String key) async {
    try {
      return await _channel.invokeMethod<bool>('set', {'key': key}) ?? false;
    } catch (e) {
      pluginWarn('Uygulama ikonu değiştirilemedi', e);
      return false;
    }
  }
}
