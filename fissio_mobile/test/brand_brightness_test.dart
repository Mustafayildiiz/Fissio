import 'package:fissio_mobile/logo.dart';
import 'package:fissio_mobile/services/widget_sync.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _MemStore implements PrefsStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

const _ink = Color(0xFF201E1D); // Mürekkep (neredeyse siyah)
const _blue = Color(0xFF1F5FD1);

void main() {
  group('brandWidgetPalette: açık/koyu parlaklığa göre', () {
    test('açık palet: zemin marka rengi, yazı kontrast, düğme tersine', () {
      final p = brandWidgetPalette(kDefaultAccent).day;
      expect(p.bg, kDefaultAccent);
      expect(p.ink, const Color(0xFFFFFFFF), reason: 'koyu/orta markada beyaz yazı');
      expect(p.btnBg, p.ink);
      expect(p.btnFg, kDefaultAccent);
    });

    test('çok açık marka rengi: koyu yazı (okunabilirlik)', () {
      final p = brandWidgetPalette(const Color(0xFFFFE08A)).day;
      expect(p.ink, const Color(0xFF201E1D));
    });

    test('koyu palet marka renginde TAKILI KALMAZ: koyu yüzey + açık yazı, düğme marka renkli', () {
      final n = brandWidgetPalette(_blue).night;
      expect(n.bg, const Color(0xFF1F1D1C), reason: 'koyu yüzey');
      expect(n.ink, const Color(0xFFF3F2F2));
      expect(n.btnBg, _blue);
      expect(n.btnFg, const Color(0xFFFFFFFF));
      expect(brandWidgetPalette(_blue).day.bg, _blue, reason: 'açık palet marka zeminli');
      expect(n.bg, isNot(brandWidgetPalette(_blue).day.bg));
    });

    test('neredeyse siyah marka: koyu paletin düğmesi açık dolgu + koyu yazı (uygulama koyu temasıyla aynı kural)', () {
      final n = brandWidgetPalette(_ink).night;
      expect(n.btnBg, const Color(0xFFE9E7E6));
      expect(n.btnFg, const Color(0xFF201E1D));
      expect(brandWidgetPalette(_ink).day.bg, _ink);
    });

    test('yerel tarafın okuduğu biçim: #AARRGGBB|… (5 alan)', () {
      final s = brandWidgetPalette(const Color(0xFFEC3013)).day.encode();
      final parts = s.split('|');
      expect(parts.length, 5);
      expect(parts.first, '#FFEC3013');
      expect(parts.every((x) => RegExp(r'^#[0-9A-F]{8}$').hasMatch(x)), isTrue);
    });

    test('anahtarlar', () {
      expect(WidgetKeys.brandDay, 'fissio_widget_brand_day');
      expect(WidgetKeys.brandNight, 'fissio_widget_brand_night');
    });
  });

  group('logo: marka rengi + tema parlaklığı', () {
    test('logoTileColorFor: yalnızca koyu temada ve yalnızca neredeyse siyah renkte açılır', () {
      expect(logoTileColorFor(_ink, Brightness.light), _ink);
      final lifted = logoTileColorFor(_ink, Brightness.dark);
      expect(lifted, isNot(_ink));
      expect(lifted.computeLuminance(), greaterThan(_ink.computeLuminance()));
      expect(logoTileColorFor(_blue, Brightness.dark), _blue);
      expect(logoTileColorFor(kDefaultAccent, Brightness.light), kDefaultAccent);
    });

    testWidgets('seçilen marka rengi logoda anında görünür; açık↔koyu geçişte near-black uyarlanır', (tester) async {
      final ctrl = ThemeController(store: _MemStore(), launcherIcon: FakeLauncherIcon(isSupported: false));
      Color painted() => ((tester
              .widget<CustomPaint>(
                find.descendant(of: find.byKey(const ValueKey('fissio-logo')), matching: find.byType(CustomPaint)),
              )
              .painter!) as FissioLogoPainter)
          .color;
      Future<void> show(Brightness b) => tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(brightness: b),
              home: Scaffold(body: FissioLogo(size: 80, controller: ctrl)),
            ),
          );

      await show(Brightness.light);
      await ctrl.setAccent(_blue);
      await tester.pump();
      expect(painted(), _blue);

      await ctrl.setLogoColor(_ink);
      await tester.pump();
      expect(painted(), _ink, reason: 'açık temada olduğu gibi');

      await show(Brightness.dark);
      await tester.pump(const Duration(milliseconds: 400)); // AnimatedTheme geçişi bitsin
      expect(painted(), isNot(_ink), reason: 'koyu zeminde kaybolmaz');
      expect(painted(), logoTileColorFor(_ink, Brightness.dark));

      await ctrl.setLogoColor(null); // temayı izle → vurgu (mavi) koyu temada aynen
      await tester.pump();
      expect(painted(), _blue);
    });
  });
}
