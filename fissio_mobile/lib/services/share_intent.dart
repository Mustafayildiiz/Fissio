import 'dart:async';

import 'package:flutter/services.dart';

import 'plugin_log.dart';

/// Başka uygulamalardan (Mail, WhatsApp, Dosyalar...) "Paylaş → Fissio" / "Birlikte aç" ile gelen PDF dosyaları.
///
/// Yerel taraf (Android `MainActivity`, iOS `AppDelegate`) dosyayı uygulama önbelleğine kopyalar ve YEREL YOLU verir;
/// Dart tarafı dosyayı hiçbir yere göndermez (okuma cihaz içidir). Testlerde sahtesi verilir.
abstract class ShareIntentPort {
  /// Uygulama paylaşılan bir dosyayla AÇILDIYSA (soğuk açılış) yolu; yoksa null.
  Future<String?> initialFile();

  /// Uygulama açıkken (sıcak açılış) gelen dosya yolları.
  Stream<String> get files;
}

class NoopShareIntent implements ShareIntentPort {
  const NoopShareIntent();
  @override
  Future<String?> initialFile() async => null;
  @override
  Stream<String> get files => const Stream<String>.empty();
}

class ChannelShareIntent implements ShareIntentPort {
  ChannelShareIntent() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onFile' && call.arguments is String) _controller.add(call.arguments as String);
    });
  }

  static const _channel = MethodChannel('fissio/share_intent');
  final _controller = StreamController<String>.broadcast();

  @override
  Future<String?> initialFile() async {
    try {
      return await _channel.invokeMethod<String>('getInitialFile');
    } catch (e) {
      // Eklenti yok (test/masaüstü) ya da yerel taraf bu platformda kurulu değil.
      pluginWarn('Paylaşılan dosya okunamadı', e);
      return null;
    }
  }

  @override
  Stream<String> get files => _controller.stream;
}

/// Uygulamanın paylaşım köprüsü (testlerde değiştirilir).
ShareIntentPort shareIntentPort = ChannelShareIntent();
