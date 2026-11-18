import 'package:home_widget/home_widget.dart';

import 'plugin_log.dart';

/// Ana ekran widget'ının gösterdiği veri: aktif profilin bu ayki toplam harcaması.
class WidgetPayload {
  const WidgetPayload({required this.profileName, required this.monthTotalText, required this.monthLabel});
  final String profileName;
  final String monthTotalText;
  final String monthLabel;

  @override
  bool operator ==(Object other) =>
      other is WidgetPayload &&
      other.profileName == profileName &&
      other.monthTotalText == monthTotalText &&
      other.monthLabel == monthLabel;

  @override
  int get hashCode => Object.hash(profileName, monthTotalText, monthLabel);
}

/// Ana ekran widget'ı için port. `update(null)` oturum yokken (çıkış / hesap silme) widget verisini temizler;
/// böylece sonraki hesap önceki kullanıcının harcamasını görmez.
abstract class WidgetSync {
  Future<void> update(WidgetPayload? payload);
}

class NoopWidgetSync implements WidgetSync {
  const NoopWidgetSync();
  @override
  Future<void> update(WidgetPayload? payload) async {}
}

/// Widget veri anahtarları (yerel Android/iOS kodu da aynı anahtarları okur).
class WidgetKeys {
  static const signedIn = 'fissio_signed_in';
  static const profile = 'fissio_profile';
  static const total = 'fissio_month_total';
  static const month = 'fissio_month_label';
  static const androidProvider = 'FissioWidgetProvider';
  static const iosWidget = 'FissioWidget';
  static const appGroup = 'group.com.example.fissioMobile';
}

class PluginWidgetSync implements WidgetSync {
  bool _groupSet = false;

  @override
  Future<void> update(WidgetPayload? payload) async {
    try {
      if (!_groupSet) {
        _groupSet = true;
        await HomeWidget.setAppGroupId(WidgetKeys.appGroup);
      }
      await HomeWidget.saveWidgetData<bool>(WidgetKeys.signedIn, payload != null);
      await HomeWidget.saveWidgetData<String>(WidgetKeys.profile, payload?.profileName ?? '');
      await HomeWidget.saveWidgetData<String>(WidgetKeys.total, payload?.monthTotalText ?? '');
      await HomeWidget.saveWidgetData<String>(WidgetKeys.month, payload?.monthLabel ?? '');
      await HomeWidget.updateWidget(androidName: WidgetKeys.androidProvider, iOSName: WidgetKeys.iosWidget);
    } catch (e) {
      // Eklenti yok (test/masaüstü) ya da widget kurulu değil: uygulama akışı etkilenmez.
      pluginWarn('Ana ekran widget\'ı güncellenemedi', e);
    }
  }
}
