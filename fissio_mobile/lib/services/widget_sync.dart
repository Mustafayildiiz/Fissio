import 'package:flutter/painting.dart' show Color;
import 'package:home_widget/home_widget.dart';

import '../theme.dart' show FissioColors;
import 'plugin_log.dart';

/// Ana ekran widget'ının gösterdiği veri: aktif profilin bu ayki toplam harcaması.
class WidgetPayload {
  const WidgetPayload({
    required this.profileName,
    required this.monthTotalText,
    required this.monthLabel,
    this.monthKey = '',
  });
  final String profileName;
  final String monthTotalText;
  final String monthLabel;

  /// Yıl-ay (ay 1-12), örn. `2026-5`: yerel taraf ay değiştiğinde eski tutarı göstermesin diye yazılır.
  final String monthKey;

  @override
  bool operator ==(Object other) =>
      other is WidgetPayload &&
      other.profileName == profileName &&
      other.monthTotalText == monthTotalText &&
      other.monthLabel == monthLabel &&
      other.monthKey == monthKey;

  @override
  int get hashCode => Object.hash(profileName, monthTotalText, monthLabel, monthKey);
}

/// Ana ekran widget'ı için port. `update(null)` oturum yokken (çıkış / hesap silme) widget verisini temizler;
/// böylece sonraki hesap önceki kullanıcının harcamasını görmez.
///
/// `updateTheme` renk temasını ve marka rengini yazar; oturumdan bağımsızdır (kısayol widget'ları giriş yapılmamışken
/// de temaya uyar).
abstract class WidgetSync {
  Future<void> update(WidgetPayload? payload);

  /// [theme] = [WidgetTheme.name]; [accentArgb] = marka teması için logo/vurgu rengi (ARGB int).
  Future<void> updateTheme(String theme, int accentArgb);
}

class NoopWidgetSync implements WidgetSync {
  const NoopWidgetSync();
  @override
  Future<void> update(WidgetPayload? payload) async {}
  @override
  Future<void> updateTheme(String theme, int accentArgb) async {}
}

/// Marka rengi (ARGB int) → yerel tarafın okuduğu `#AARRGGBB` metni.
String widgetAccentHex(int argb) => '#${(argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// Marka temalı widget'ın bir moddaki (açık/koyu) renkleri.
class BrandWidgetColors {
  const BrandWidgetColors({required this.bg, required this.ink, required this.mute, required this.btnBg, required this.btnFg});
  final Color bg;
  final Color ink;
  final Color mute;
  final Color btnBg;
  final Color btnFg;

  /// Yerel tarafın okuduğu `#bg|#ink|#mute|#btnBg|#btnFg` (her biri `#AARRGGBB`).
  String encode() => [bg, ink, mute, btnBg, btnFg].map((c) => widgetAccentHex(c.toARGB32())).join('|');
}

/// Marka renginden AÇIK ve KOYU widget paleti (yerel taraf gün/gece'yi çizim anında seçer).
///  - açık: zemin marka rengi; yazı, zeminin açıklığına göre beyaz ya da koyu (kontrast); düğme zemini yazı rengi,
///    düğme yazı/ikonu marka rengi.
///  - koyu: koyu yüzey + açık yazı; düğme marka renkli (neredeyse siyah markalarda açık dolgu + koyu yazı) —
///    uygulamanın koyu teması ([FissioColors.dark]) ile aynı kural.
({BrandWidgetColors day, BrandWidgetColors night}) brandWidgetPalette(Color accent) {
  final lightOnAccent = accent.computeLuminance() > .55 ? const Color(0xFF201E1D) : const Color(0xFFFFFFFF);
  final day = BrandWidgetColors(
    bg: accent,
    ink: lightOnAccent,
    mute: lightOnAccent.withAlpha(0xCC),
    btnBg: lightOnAccent,
    btnFg: accent,
  );
  final d = FissioColors.dark(accent);
  final night = BrandWidgetColors(bg: d.surf, ink: d.ink, mute: d.mute, btnBg: d.accent, btnFg: d.onAccent);
  return (day: day, night: night);
}

/// Widget veri anahtarları (yerel Android/iOS kodu da aynı anahtarları okur).
class WidgetKeys {
  static const signedIn = 'fissio_signed_in';
  static const profile = 'fissio_profile';
  static const total = 'fissio_month_total';
  static const month = 'fissio_month_label';
  static const monthKey = 'fissio_month_key';

  /// Renk teması (`WidgetTheme.name`: system|light|dark|brand) ve marka rengi (`#AARRGGBB` metni, bkz. [widgetAccentHex]).
  static const theme = 'fissio_widget_theme';
  static const accent = 'fissio_widget_accent';

  /// Marka teminin açık / koyu paleti ([brandWidgetPalette]); yerel taraf telefonun gece moduna göre çizimde seçer.
  static const brandDay = 'fissio_widget_brand_day';
  static const brandNight = 'fissio_widget_brand_night';

  /// Uygulamadaki 4 ana ekran widget'ı: (Android sağlayıcı sınıfı, iOS widget `kind`). 1: toplam + OCR + Dijital,
  /// 2: yalnızca OCR tara, 3: yalnızca dijital fiş ekle, 4: ikili (OCR + Dijital) kısayol.
  static const providers = <({String android, String ios})>[
    (android: 'FissioWidgetProvider', ios: 'FissioWidget'),
    (android: 'FissioScanWidgetProvider', ios: 'FissioScanWidget'),
    (android: 'FissioDigitalWidgetProvider', ios: 'FissioDigitalWidget'),
    (android: 'FissioCombinedWidgetProvider', ios: 'FissioCombinedWidget'),
  ];

  /// `androidName` uygulama kimliğine (applicationId) göre çözülür; sınıfın tam adını açıkça veriyoruz.
  static String androidQualified(String cls) => 'com.example.fissio_mobile.$cls';
  static const appGroup = 'group.com.example.fissioMobile';
}

class PluginWidgetSync implements WidgetSync {
  bool _groupSet = false;

  @override
  Future<void> update(WidgetPayload? payload) async {
    try {
      await _ensureGroup();
      await HomeWidget.saveWidgetData<bool>(WidgetKeys.signedIn, payload != null);
      await HomeWidget.saveWidgetData<String>(WidgetKeys.profile, payload?.profileName ?? '');
      await HomeWidget.saveWidgetData<String>(WidgetKeys.total, payload?.monthTotalText ?? '');
      await HomeWidget.saveWidgetData<String>(WidgetKeys.month, payload?.monthLabel ?? '');
      await HomeWidget.saveWidgetData<String>(WidgetKeys.monthKey, payload?.monthKey ?? '');
      await _refreshAll();
    } catch (e) {
      // Eklenti yok (test/masaüstü) ya da widget kurulu değil: uygulama akışı etkilenmez.
      pluginWarn('Ana ekran widget\'ı güncellenemedi', e);
    }
  }

  @override
  Future<void> updateTheme(String theme, int accentArgb) async {
    try {
      await _ensureGroup();
      await HomeWidget.saveWidgetData<String>(WidgetKeys.theme, theme);
      // Yerel taraf `Color.parseColor` / hex okur: `#AARRGGBB` (ARGB int 32 bit'e sığmayabilir, metin olarak yazılır).
      await HomeWidget.saveWidgetData<String>(WidgetKeys.accent, widgetAccentHex(accentArgb));
      final palette = brandWidgetPalette(Color(accentArgb));
      await HomeWidget.saveWidgetData<String>(WidgetKeys.brandDay, palette.day.encode());
      await HomeWidget.saveWidgetData<String>(WidgetKeys.brandNight, palette.night.encode());
      await _refreshAll();
    } catch (e) {
      pluginWarn('Widget teması güncellenemedi', e);
    }
  }

  Future<void> _ensureGroup() async {
    if (_groupSet) return;
    _groupSet = true;
    await HomeWidget.setAppGroupId(WidgetKeys.appGroup);
  }

  /// 4 widget'ın hepsini yeniden çizdirir (AppWidgetManager / WidgetCenter); biri kurulu değilse diğerleri etkilenmez.
  Future<void> _refreshAll() async {
    for (final w in WidgetKeys.providers) {
      try {
        await HomeWidget.updateWidget(
          qualifiedAndroidName: WidgetKeys.androidQualified(w.android),
          androidName: w.android,
          iOSName: w.ios,
        );
      } catch (e) {
        pluginWarn('Widget güncellenemedi (${w.android})', e);
      }
    }
  }
}
