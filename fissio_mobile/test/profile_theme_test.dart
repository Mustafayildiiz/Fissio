import 'package:fissio_mobile/pages/preferences_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';
import 'support/fakes.dart' show FakeLauncherIcon;

/// "Profile özel tema kullan": varsayılan ortak tema; açıkken tema modu, vurgu, logo ve widget teması profil başına
/// saklanır ve profil değişince senkron uygulanır; kapatınca ortak temaya dönülür.

class _MemStore implements PrefsStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

const _blue = Color(0xFF1F5FD1);
const _green = Color(0xFF00A86B);

void main() {
  group('ThemeController profil teması', () {
    test('varsayılan kapalı: profil değişimi temayı değiştirmez, yazımlar ortak anahtarlara gider', () async {
      final store = _MemStore();
      final c = ThemeController(store: store);
      await c.load();
      expect(c.perProfileTheme, isFalse);
      c.setActiveProfile('A');
      await c.setThemeMode(ThemeMode.dark);
      c.setActiveProfile('B');
      expect(c.themeMode, ThemeMode.dark);
      expect(store.map[ThemeController.modeKey], 'dark');
      expect(store.map[ThemeController.profileThemesKey], isNull);
    });

    test('açıkken profil A/B ayrı; geçiş senkron; kalıcı; kapatınca ortak, yeniden açınca profil kaydı geri gelir', () async {
      final store = _MemStore();
      final c = ThemeController(store: store);
      await c.load();
      await c.setThemeMode(ThemeMode.dark); // ortak
      c.setActiveProfile('B');
      await c.setPerProfileTheme(true);
      expect(c.themeMode, ThemeMode.dark, reason: 'profil kaydı ortak temadan başlar');

      await c.setThemeMode(ThemeMode.light);
      await c.setAccent(_blue);
      await c.setLogoColor(_green);
      await c.setWidgetTheme(WidgetTheme.brand);
      expect(store.map[ThemeController.modeKey], 'dark', reason: 'ortak tercih değişmez');
      expect(store.map[ThemeController.widgetThemeKey], isNull);

      var notified = 0;
      c.addListener(() => notified++);
      c.setActiveProfile('A'); // kaydı yok -> ortak
      expect(notified, 1, reason: 'geçiş senkron');
      expect(c.themeMode, ThemeMode.dark);
      expect(c.accent.toARGB32(), kDefaultAccent.toARGB32());
      expect(c.logoOverride, isNull);
      expect(c.widgetTheme, WidgetTheme.system);

      c.setActiveProfile('B');
      expect(c.themeMode, ThemeMode.light);
      expect(c.accent.toARGB32(), _blue.toARGB32());
      expect(c.logoOverride?.toARGB32(), _green.toARGB32());
      expect(c.widgetTheme, WidgetTheme.brand);

      // Kalıcı: aynı depodan yeni denetleyici (profil, load'dan önce bildirilebilir).
      final c2 = ThemeController(store: store);
      c2.setActiveProfile('B');
      await c2.load();
      expect(c2.perProfileTheme, isTrue);
      expect(c2.themeMode, ThemeMode.light);
      expect(c2.widgetTheme, WidgetTheme.brand);

      await c.setPerProfileTheme(false);
      expect(c.themeMode, ThemeMode.dark, reason: 'ortak temaya dönülür');
      expect(c.widgetTheme, WidgetTheme.system);
      await c.setPerProfileTheme(true);
      expect(c.themeMode, ThemeMode.light, reason: 'profil kaydı korunur');
      c.dispose();
      c2.dispose();
    });

    test('ana ekran ikonu yalnız ORTAK temanın logosunu izler; profil teması/geçişi ikonu değiştirmez', () async {
      final launcher = FakeLauncherIcon();
      final c = ThemeController(store: _MemStore(), launcherIcon: launcher);
      await c.load();
      await c.setLogoColor(_blue); // ortak: ikon değişir (gecikmeli)
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(launcher.applied.last, brandKeyOf(_blue));
      final n = launcher.applied.length;

      c.setActiveProfile('B');
      await c.setPerProfileTheme(true);
      await c.setLogoColor(_green); // yalnız B profili
      await c.setAccent(_green);
      expect(c.logoColor.toARGB32(), _green.toARGB32(), reason: 'uygulama içi logo profili izler');
      expect(c.launcherColor.toARGB32(), _blue.toARGB32(), reason: 'ikon ortak temayı izler');
      c.setActiveProfile('A');
      c.setActiveProfile('B');
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(launcher.applied.length, n, reason: 'profil teması/geçişi ikonu değiştirmez');

      await c.setPerProfileTheme(false);
      await c.setLogoColor(_green); // ortak değişti: ikon izler
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(launcher.applied.last, brandKeyOf(_green));
      c.dispose();
    });

    test('bozuk profil teması JSON\'u yok sayılır', () async {
      final store = _MemStore()
        ..map[ThemeController.perProfileKey] = 'true'
        ..map[ThemeController.profileThemesKey] = '{"A": {"accent": "x"}, "B": 5, bozuk';
      final c = ThemeController(store: store);
      c.setActiveProfile('A');
      await c.load();
      expect(c.perProfileTheme, isTrue);
      expect(c.themeMode, ThemeMode.system);
      expect(parseProfileThemes('{"A": {"accent": 1, "mode": "dark"}, "B": 5}').keys, ['A']);
    });
  });

  group('AppState ↔ global tema', () {
    late ThemeMode prevMode;
    setUp(() => prevMode = themeController.themeMode);
    tearDown(() async {
      await themeController.setPerProfileTheme(false);
      await themeController.setThemeMode(prevMode);
    });

    test('aktif profil değişince profilin teması uygulanır; çıkışta ortak temaya dönülür', () async {
      final h = Harness();
      await h.signIn('tema@x.co');
      final personal = h.app.activeProfile!;
      await h.app.createProfile('İş');
      await h.settle();
      final work = h.app.activeProfile!;
      expect(themeController.activeProfileUid, work.id);

      await themeController.setThemeMode(ThemeMode.light); // ortak
      await themeController.setPerProfileTheme(true);
      await themeController.setThemeMode(ThemeMode.dark); // yalnız İş

      await h.app.selectProfile(personal);
      await h.settle();
      expect(themeController.activeProfileUid, personal.id);
      expect(themeController.themeMode, ThemeMode.light);

      await h.app.selectProfile(work);
      await h.settle();
      expect(themeController.themeMode, ThemeMode.dark);

      await h.app.logout();
      await h.settle();
      expect(themeController.activeProfileUid, isNull);
      expect(themeController.themeMode, ThemeMode.light);
    });
  });

  testWidgets('Tercihler: "Profile özel tema kullan" ve "Başarısız e-posta aktarımlarında bilgilendir" anahtarları',
      (tester) async {
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final prevPer = themeController.perProfileTheme;
    late Harness h;
    await tester.runAsync(() async {
      h = Harness();
      await h.signIn('pref@x.co');
      await h.app.loadInbound();
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: PreferencesPage(app: h.app)));
    await tester.runAsync(() => h.settle());
    await tester.pump();

    final perProfile = find.byKey(const Key('theme-per-profile-switch'));
    expect(perProfile, findsOneWidget);
    expect(tester.widget<Switch>(perProfile).value, isFalse);
    expect(find.textContaining('tüm profiller aynı'), findsOneWidget);
    await tester.tap(perProfile);
    await tester.pump();
    expect(themeController.perProfileTheme, isTrue);
    expect(find.textContaining('"Kişisel" profili için ayrı saklanır'), findsOneWidget);

    final notify = find.byKey(const Key('inbound-notify-switch'));
    expect(notify, findsOneWidget);
    expect(tester.widget<Switch>(notify).value, isTrue, reason: 'varsayılan açık');
    await tester.ensureVisible(notify);
    await tester.tap(notify);
    await tester.pump();
    await tester.runAsync(() => h.settle());
    await tester.pump();
    expect(h.backend.user('pref@x.co').notifyFailures, isFalse);
    expect(tester.widget<Switch>(notify).value, isFalse);

    await tester.pumpWidget(const SizedBox());
    themeController.perProfileTheme = prevPer;
  });
}
