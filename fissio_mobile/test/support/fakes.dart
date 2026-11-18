import 'package:fissio_mobile/services/launcher_icon.dart';
import 'package:fissio_mobile/services/notifier.dart';
import 'package:fissio_mobile/services/widget_sync.dart';

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
