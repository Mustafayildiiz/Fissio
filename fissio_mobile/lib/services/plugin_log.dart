import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MissingPluginException;

/// Platform eklentisi hatalarını kaydeder; eklenti hiç yoksa (test/masaüstü) sessiz kalır.
void pluginWarn(String what, Object error) {
  // Eklenti platform tarafında kayıtlı değil (test/masaüstü): beklenen durum, günlüğe yazılmaz.
  if (error is MissingPluginException || error.runtimeType.toString() == 'LateInitializationError') return;
  debugPrint('$what: $error');
}
