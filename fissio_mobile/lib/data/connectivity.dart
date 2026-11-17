import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Ağ bağlantısı durumu (testlerde sahtesi verilir). `true` = bir ağ var (internet garantisi değildir;
/// asıl doğrulama başarılı API isteğidir).
abstract class ConnectivityMonitor {
  Stream<bool> get onChanged;
  Future<bool> isOnline();
}

class PluginConnectivity implements ConnectivityMonitor {
  PluginConnectivity();

  Connectivity? _c;
  Connectivity get _conn => _c ??= Connectivity();

  @override
  Stream<bool> get onChanged =>
      _conn.onConnectivityChanged.map((r) => !r.contains(ConnectivityResult.none));

  @override
  Future<bool> isOnline() async {
    try {
      return !(await _conn.checkConnectivity()).contains(ConnectivityResult.none);
    } catch (_) {
      return true; // bilinemiyorsa denemeyi engelleme
    }
  }
}

/// Hiçbir şey yapmayan monitör (eklenti yokken / testlerde varsayılan olarak kullanılabilir).
class NoopConnectivity implements ConnectivityMonitor {
  const NoopConnectivity();
  @override
  Stream<bool> get onChanged => const Stream.empty();
  @override
  Future<bool> isOnline() async => true;
}
