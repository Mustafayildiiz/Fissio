import 'package:fissio_mobile/onboarding_controller.dart';
import 'package:fissio_mobile/pages/onboarding_page.dart';
import 'package:fissio_mobile/pages/settings_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/theme_controller.dart' show PrefsStore;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemStore implements PrefsStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

Widget _app(Widget home, {Brightness brightness = Brightness.light, Color? accent}) =>
    MaterialApp(
      theme: buildTheme(brightness: brightness, accent: accent ?? kDefaultAccent),
      home: home,
    );

void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('akış', () {
    testWidgets('Devam ile 1/3 → 3/3 ilerler; son sayfada Atla yok, Başlayalım var', (tester) async {
      _tallScreen(tester);
      final ctrl = OnboardingController(store: _MemStore());
      await tester.pumpWidget(_app(OnboardingPage(controller: ctrl, onDone: () {})));

      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.text('Atla'), findsOneWidget);
      expect(find.text('Devam'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('onb-primary')));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
      expect(find.text('Elle eklemek de birkaç saniye'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('onb-primary')));
      await tester.pumpAndSettle();
      expect(find.text('3 / 3'), findsOneWidget);
      expect(find.text('Atla'), findsNothing);
      expect(find.text('Başlayalım'), findsOneWidget);
    });

    testWidgets('sona kadar tamamlayınca onDone çağrılır ve Ayarlar satırı kalıcı gizlenir', (tester) async {
      _tallScreen(tester);
      final store = _MemStore();
      final ctrl = OnboardingController(store: store);
      var done = 0;
      await tester.pumpWidget(_app(OnboardingPage(
        controller: ctrl,
        email: 'yeni@fissio.app',
        onDone: () => done++,
      )));
      await tester.pump();

      // Kayıt akışı açılır açılmaz görüldü olarak işaretlenir.
      expect(await ctrl.shouldShowAfterSignUp('yeni@fissio.app'), isFalse);

      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const ValueKey('onb-primary')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('onb-primary')));
      await tester.pumpAndSettle();

      expect(done, 1);
      final restarted = OnboardingController(store: store);
      await restarted.load();
      expect(await restarted.shouldShowAfterSignUp('yeni@fissio.app'), isFalse);
    });

    testWidgets('Atla akışı bitirir; otomatik gösterim kapanır', (tester) async {
      _tallScreen(tester);
      final store = _MemStore();
      final ctrl = OnboardingController(store: store);
      var done = 0;
      await tester.pumpWidget(_app(OnboardingPage(
        controller: ctrl,
        email: 'a@fissio.app',
        onDone: () => done++,
      )));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('onb-skip')));
      await tester.pumpAndSettle();

      expect(done, 1);
      expect(await ctrl.shouldShowAfterSignUp('a@fissio.app'), isFalse);
    });
  });

  group('Ayarlar satırı', () {
    const rowLabel = 'Uygulama Rehberi / Tanıtımı';

    testWidgets('satır görünür; açılan rehber kapanınca Ayarlara dönülür ve satır görünür kalır', (tester) async {
      _tallScreen(tester);
      final store = _MemStore();
      final ctrl = OnboardingController(store: store);
      await ctrl.load();
      await tester.pumpWidget(_app(SettingsPage(onboarding: ctrl)));
      await tester.pump();

      expect(find.text(rowLabel), findsOneWidget);
      await tester.tap(find.text(rowLabel));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('onb-skip')));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingPage), findsNothing);
      expect(find.text(rowLabel), findsOneWidget);

      // Tamamlayarak da aynı: tekrar açılabilir.
      await tester.tap(find.text(rowLabel));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('onb-primary')));
        await tester.pumpAndSettle();
      }
      expect(find.byType(OnboardingPage), findsNothing);
      expect(find.text(rowLabel), findsOneWidget);
    });

    testWidgets('kayıtta tamamlayan ya da eski bayrağı olan cihazda da görünür', (tester) async {
      _tallScreen(tester);
      final store = _MemStore();
      await store.write(OnboardingController.legacyReplayUsedKey, '1');
      final ctrl = OnboardingController(store: store);
      await ctrl.load();
      await tester.pumpWidget(_app(SettingsPage(onboarding: ctrl)));
      await tester.pump();
      expect(find.text(rowLabel), findsOneWidget);
    });
  });

  group('tema uyumu', () {
    for (final brightness in Brightness.values) {
      for (final option in kAccentOptions) {
        testWidgets('${brightness.name} / ${option.name}: bileşenler tema renkleriyle çizilir', (tester) async {
          _tallScreen(tester);
          final ctrl = OnboardingController(store: _MemStore());
          await tester.pumpWidget(_app(
            OnboardingPage(controller: ctrl, onDone: () {}),
            brightness: brightness,
            accent: option.color,
          ));
          await tester.pump();

          final context = tester.element(find.byType(OnboardingPage));
          final c = context.c;
          expect(c.isDark, brightness == Brightness.dark);
          // Koyu zeminde neredeyse siyah vurgular (Grafit, Mürekkep) görünmez kalmasın diye açık dolguya çevrilir
          // (bkz. FissioColors.dark); diğer tüm vurgular seçilen renkle birebir aynıdır.
          if (brightness == Brightness.dark && option.color.computeLuminance() < .08) {
            expect(c.accent.computeLuminance(), greaterThan(.5));
          } else {
            expect(c.accent, option.color);
          }

          // Zemin, başlık, açıklama.
          expect(tester.widget<Scaffold>(find.byType(Scaffold)).body, isNotNull);
          expect(Theme.of(context).scaffoldBackgroundColor, c.bg);
          expect(tester.widget<Text>(find.byKey(const ValueKey('onb-title-0'))).style!.color, c.ink);
          expect(tester.widget<Text>(find.byKey(const ValueKey('onb-body-0'))).style!.color, c.mute);
          expect(tester.widget<Text>(find.byKey(const ValueKey('onb-counter'))).style!.color, c.mute);

          // Aktif nokta vurgu, pasif noktalar seg4; birincil düğme vurgu rengi.
          BoxDecoration deco(Key k) =>
              tester.widget<AnimatedContainer>(find.byKey(k)).decoration! as BoxDecoration;
          expect(deco(const ValueKey('onb-dot-active')).color, c.accent);
          expect(deco(const ValueKey('onb-dot-1')).color, c.seg4);
          final button = tester.widget<Material>(find.descendant(
            of: find.byKey(const ValueKey('onb-primary')),
            matching: find.byType(Material),
          ).first);
          expect(button.color, c.accent);

          // Tarama vizörü çizgisi vurgu rengini kullanır.
          final line = tester.widget<Container>(find.byKey(const ValueKey('onb-scan-line')));
          expect((line.decoration! as BoxDecoration).color, c.accent);

          // 2. ve 3. adımlar da hatasız ve temaya bağlı çizilir.
          await tester.tap(find.byKey(const ValueKey('onb-primary')));
          await tester.pumpAndSettle();
          final chip = tester.widget<Container>(find.byKey(const ValueKey('onb-chip')));
          expect(
            (chip.decoration! as BoxDecoration).color,
            c.accent.withValues(alpha: .15),
          );
          await tester.tap(find.byKey(const ValueKey('onb-primary')));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('onb-hero-stats')), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('tema değişince renkler yeniden hesaplanır (açık → koyu)', (tester) async {
      _tallScreen(tester);
      final ctrl = OnboardingController(store: _MemStore());
      final mode = ValueNotifier(ThemeMode.light);
      await tester.pumpWidget(ValueListenableBuilder<ThemeMode>(
        valueListenable: mode,
        builder: (_, m, _) => MaterialApp(
          theme: buildTheme(),
          darkTheme: buildTheme(brightness: Brightness.dark),
          themeMode: m,
          home: OnboardingPage(controller: ctrl, onDone: () {}),
        ),
      ));
      await tester.pump();
      Color? titleColor() =>
          tester.widget<Text>(find.byKey(const ValueKey('onb-title-0'))).style!.color;
      final light = titleColor();
      mode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(titleColor(), isNot(light));
      expect(titleColor(), FissioColors.dark().ink);
    });
  });
}
