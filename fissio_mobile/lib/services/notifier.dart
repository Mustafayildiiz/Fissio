import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'plugin_log.dart';

/// Yerel bildirimler için port (bütçe eşikleri ve ödeme hatırlatıcıları). Eklenti arkasında soyutlanır: testler
/// sahte uygulama kullanır, eklenti yoksa (masaüstü/test) çağrılar sessizce yutulur.
abstract class LocalNotifier {
  /// Bildirim iznini ister (Android 13+/iOS); verildiyse true. Eklenti yoksa false.
  Future<bool> requestPermission();

  /// Hemen bildirim gösterir. Aynı [id] önceki bildirimi yer değiştirir.
  Future<void> show({required int id, required String title, required String body, String? payload});

  /// [when] (yerel zaman) anında tek seferlik bildirim planlar.
  Future<void> schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
    String? payload,
  });

  /// Planlanmış (henüz gösterilmemiş) tüm bildirimleri iptal eder; ödeme hatırlatıcıları yeniden planlanırken.
  Future<void> cancelScheduled();

  /// Planlanmış ve gösterilmiş tüm bildirimleri kaldırır (çıkış / hesap silme).
  Future<void> cancelAll();
}

class NoopNotifier implements LocalNotifier {
  const NoopNotifier();
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<void> show({required int id, required String title, required String body, String? payload}) async {}
  @override
  Future<void> schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
    String? payload,
  }) async {}
  @override
  Future<void> cancelScheduled() async {}
  @override
  Future<void> cancelAll() async {}
}

/// `flutter_local_notifications` uygulaması. Kurucuda platform kanalına dokunmaz (global `appState` testlerde de
/// oluşur); ilk kullanımda tembel başlatılır ve her çağrı eklenti hatalarına karşı korunur.
class PluginLocalNotifier implements LocalNotifier {
  PluginLocalNotifier();

  FlutterLocalNotificationsPlugin? _plugin;
  Future<bool>? _init;

  static const _channelId = 'fissio_alerts';
  static const _channelName = 'Bütçe ve ödeme uyarıları';

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Bütçe limiti uyarıları ve yaklaşan ödeme hatırlatıcıları',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
  );

  Future<FlutterLocalNotificationsPlugin?> _ready() async {
    try {
      _init ??= _initialize();
      return await _init! ? _plugin : null;
    } catch (e) {
      pluginWarn('Bildirim eklentisi hazır değil', e);
      return null;
    }
  }

  Future<bool> _initialize() async {
    final plugin = _plugin ??= FlutterLocalNotificationsPlugin();
    // İzin ilk bildirimde ayrıca istenir (requestPermission); başlatma izin penceresi açmaz.
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await plugin.initialize(settings: settings);
    return true;
  }

  @override
  Future<bool> requestPermission() async {
    final p = await _ready();
    if (p == null) return false;
    try {
      final android = p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) return await android.requestNotificationsPermission() ?? false;
      final ios = p.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) return await ios.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    } catch (e) {
      pluginWarn('Bildirim izni istenemedi', e);
    }
    return false;
  }

  @override
  Future<void> show({required int id, required String title, required String body, String? payload}) async {
    final p = await _ready();
    if (p == null) return;
    try {
      await p.show(id: id, title: title, body: body, notificationDetails: _details, payload: payload);
    } catch (e) {
      pluginWarn('Bildirim gösterilemedi', e);
    }
  }

  @override
  Future<void> schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
    String? payload,
  }) async {
    final p = await _ready();
    if (p == null) return;
    try {
      // Tek seferlik mutlak an: tz.UTC üzerinde aynı anı gösterir (zaman dilimi veritabanı gerekmez).
      await p.zonedSchedule(
        id: id,
        scheduledDate: tz.TZDateTime.from(when, tz.UTC),
        notificationDetails: _details,
        // Tam alarm izni gerektirmez; ödeme hatırlatıcısı için dakikalık hassasiyet gerekmez.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: title,
        body: body,
        payload: payload,
      );
    } catch (e) {
      pluginWarn('Bildirim planlanamadı', e);
    }
  }

  @override
  Future<void> cancelScheduled() async {
    final p = await _ready();
    try {
      await p?.cancelAllPendingNotifications();
    } catch (e) {
      pluginWarn('Planlı bildirimler iptal edilemedi', e);
    }
  }

  @override
  Future<void> cancelAll() async {
    final p = await _ready();
    try {
      await p?.cancelAll();
    } catch (e) {
      pluginWarn('Bildirimler iptal edilemedi', e);
    }
  }
}
