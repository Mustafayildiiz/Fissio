import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/pages/email_setup_wizard.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Kurulum rehberi her zaman açılır-kapanır: bağlı değilken açık, bağlıyken kapalı başlar; kullanıcının seçimi
/// yoklama/yeniden çizimde korunur, yalnız adres değişince (yenileme) bir kez açılır. Yoklama bağlanınca seyrelir.

const _email = 'ali@x.co';

Widget _app(Widget home) => MaterialApp(theme: buildTheme(), home: home);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 6000);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<Harness> _signedIn(WidgetTester tester, {bool connected = false}) async {
  late Harness h;
  await tester.runAsync(() async {
    h = Harness(clock: () => DateTime(2026, 11, 20));
    await h.signIn(_email);
    if (connected) h.backend.user(_email).lastReceivedAt = '2026-11-20T20:05:00Z';
    await h.app.loadInbound();
  });
  return h;
}

Future<void> _flush(WidgetTester tester, Harness h) async {
  await tester.runAsync(() => h.settle());
  await tester.pump();
}

void main() {
  testWidgets('bağlı değilken rehber açık başlar; kullanıcı kapatabilir ve yoklamalar boyunca kapalı kalır', (tester) async {
    _tall(tester);
    final h = await _signedIn(tester);
    await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(milliseconds: 100))));
    await _flush(tester, h);
    expect(find.byKey(const ValueKey('wiz-guide')), findsOneWidget);
    expect(find.byKey(const ValueKey('wiz-step-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('wiz-filter-step-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('wiz-address-compact')), findsNothing);

    await tester.tap(find.text('Kurulum Rehberi'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('wiz-step-1')), findsNothing, reason: 'kullanıcı kapattı');
    // Birkaç yoklama + yeniden çizim: kullanıcının kapatma seçimi sıfırlanmaz.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 150));
      await _flush(tester, h);
    }
    expect(find.byKey(const ValueKey('wiz-step-1')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('bağlıyken rehber "Kurulum Rehberi" altında kapalı; adres kısayolu ve diğer kartlar görünür; açılınca adımlar gelir', (tester) async {
    _tall(tester);
    final h = await _signedIn(tester, connected: true);
    await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
    await _flush(tester, h);

    expect(find.byKey(const ValueKey('wiz-guide')), findsOneWidget);
    expect(find.text('Kurulum Rehberi'), findsOneWidget);
    expect(find.byKey(const ValueKey('wiz-step-1')), findsNothing, reason: 'uzun rehber gizli');
    expect(find.byKey(const ValueKey('wiz-filter-step-1')), findsNothing);
    expect(find.byKey(const ValueKey('wiz-address-compact')), findsOneWidget);
    expect(find.byKey(const ValueKey('wiz-status')), findsOneWidget);
    expect(find.byKey(const ValueKey('wiz-test-connection')), findsOneWidget);
    expect(find.byKey(const ValueKey('wiz-rotate')), findsOneWidget);

    await tester.tap(find.text('Kurulum Rehberi'));
    await tester.pump(); // sihirbaz açıkken bekleyen onay göstergesi sonsuz döner: pumpAndSettle yok
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('wiz-step-1')), findsOneWidget);
    for (var i = 1; i <= 5; i++) {
      expect(find.byKey(ValueKey('wiz-filter-step-$i')), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('bağlıyken açılan rehber yoklama/yeniden çizimde açık kalır; sayfa yeniden açılınca kapalı başlar', (tester) async {
    _tall(tester);
    final h = await _signedIn(tester, connected: true);
    await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(milliseconds: 100))));
    await _flush(tester, h);
    await tester.tap(find.text('Kurulum Rehberi'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('wiz-step-1')), findsOneWidget);
    h.backend.user(_email).lastStatus = 'created'; // durum değişti -> yeniden çizim
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 150));
      await _flush(tester, h);
    }
    expect(find.byKey(const ValueKey('wiz-step-1')), findsOneWidget, reason: 'kullanıcının açma seçimi korunur');
    await tester.pumpWidget(const SizedBox());

    await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
    await _flush(tester, h);
    expect(find.byKey(const ValueKey('wiz-step-1')), findsNothing, reason: 'yeniden açılışta bağlıyken kapalı');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('adres yenilenince rehber bir kez açık gelir; sonra kullanıcının kapatma seçimi korunur', (tester) async {
    _tall(tester);
    final h = await _signedIn(tester, connected: true);
    await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
    await _flush(tester, h);
    expect(find.byKey(const ValueKey('wiz-guide')), findsOneWidget);
    expect(find.byKey(const ValueKey('wiz-step-1')), findsNothing);

    await tester.ensureVisible(find.byKey(const ValueKey('wiz-rotate')));
    await tester.tap(find.byKey(const ValueKey('wiz-rotate')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Yenile'));
    await tester.pump();
    await _flush(tester, h);
    await tester.pump(const Duration(milliseconds: 500));

    expect(h.app.inbound!.active, isFalse);
    expect(find.byKey(const ValueKey('wiz-guide')), findsOneWidget);
    expect(find.byKey(const ValueKey('wiz-step-1')), findsOneWidget, reason: 'yeni adresin kurulumu için açık');
    expect(find.byKey(const ValueKey('wiz-confirm-waiting')), findsOneWidget);

    await tester.tap(find.text('Kurulum Rehberi'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('wiz-step-1')), findsNothing);
    // İlk mail yeni adrese geldi (bağlandı): kullanıcının kapatma seçimi bozulmaz, kendiliğinden açılmaz.
    h.backend.user(_email).lastReceivedAt = '2026-11-20T21:00:00Z';
    await tester.runAsync(() => h.app.loadInbound());
    await tester.pump();
    expect(h.app.inbound!.active, isTrue);
    expect(find.byKey(const ValueKey('wiz-step-1')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('yoklama: bağlı değilken 5 sn, bağlandıktan sonra 30 sn aralıkla (varsayılan aralıkta)', (tester) async {
    _tall(tester);
    final waiting = await _signedIn(tester);
    await tester.pumpWidget(_app(EmailSetupWizardPage(app: waiting.app)));
    await _flush(tester, waiting);
    final before = waiting.backend.confirmationPolls;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester, waiting);
    }
    expect(waiting.backend.confirmationPolls - before, greaterThanOrEqualTo(3), reason: 'onay beklerken sık yoklanır');
    await tester.pumpWidget(const SizedBox());

    final connected = await _signedIn(tester, connected: true);
    await tester.pumpWidget(_app(EmailSetupWizardPage(app: connected.app)));
    await _flush(tester, connected);
    final c0 = connected.backend.confirmationPolls;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester, connected);
    }
    expect(connected.backend.confirmationPolls - c0, 0, reason: '20 sn içinde seyrek aralık tetiklenmez');
    await tester.pump(const Duration(seconds: 15));
    await _flush(tester, connected);
    expect(connected.backend.confirmationPolls - c0, 1, reason: '30 sn dolunca bir yoklama');
    await tester.pumpWidget(const SizedBox());
  });

  group('AppState.loadInbound', () {
    test('değişmeyen durumda dinleyicileri tetiklemez; değişince tetikler', () async {
      final h = Harness();
      await h.signIn(_email);
      await h.app.loadInbound();
      var n = 0;
      h.app.addListener(() => n++);
      await h.app.loadInbound();
      await h.app.loadInbound();
      expect(n, 0, reason: 'sihirbaz yoklaması tüm uygulamayı yeniden çizdirmez');
      h.backend.user(_email).lastReceivedAt = '2026-11-20T20:05:00Z';
      await h.app.loadInbound();
      expect(n, 1);
    });

    test('InboundAddress değer eşitliği', () {
      const a = InboundAddress(enabled: true, address: 'x@y', paused: true);
      const b = InboundAddress(enabled: true, address: 'x@y', paused: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const InboundAddress(enabled: true, address: 'x@y'), isFalse);
    });
  });
}
