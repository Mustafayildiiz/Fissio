import 'package:fissio_mobile/app_info.dart';
import 'package:fissio_mobile/onboarding_controller.dart';
import 'package:fissio_mobile/pages/account_ready_page.dart';
import 'package:fissio_mobile/pages/email_import_card.dart';
import 'package:fissio_mobile/pages/email_setup_wizard.dart';
import 'package:fissio_mobile/pages/onboarding_page.dart';
import 'package:fissio_mobile/pages/settings_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/theme_controller.dart' show PrefsStore;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

// E-posta ile otomatik fiş aktarımı arayüzü: ilk açılış onboarding'inin opsiyonel 4. adımı, Ayarlar'daki iki bağımsız rehber girişi,
// interaktif kurulum sihirbazı (kopyala / canlı Gmail onayı / durum satırı) ve ana sayfadaki kapatılabilir "Yeni" kartı.

const _email = 'ali@x.co';

class _MemStore implements PrefsStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

Widget _app(Widget home) => MaterialApp(theme: buildTheme(brightness: Brightness.light, accent: kDefaultAccent), home: home);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 6000);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<Harness> _signedIn(WidgetTester tester, {bool inbound = true, bool sync = true}) async {
  late Harness h;
  await tester.runAsync(() async {
    h = Harness(clock: () => DateTime(2026, 11, 20));
    h.backend.inboundEnabled = inbound;
    await h.signIn(_email);
    if (!sync) await h.app.setSyncEnabled(false);
    await h.app.loadInbound();
  });
  return h;
}

/// Ağ çağrıları (MockClient) için mikro-görevleri akıt.
Future<void> _flush(WidgetTester tester, Harness h) async {
  await tester.runAsync(() => h.settle());
  await tester.pump();
}

void main() {
  final copied = <String>[];
  final opened = <Uri>[];
  final savedClip = clipboardWriter;
  final savedOpen = externalLinkLauncher;

  setUp(() {
    copied.clear();
    opened.clear();
    clipboardWriter = (t) async => copied.add(t);
    externalLinkLauncher = (u) async {
      opened.add(u);
      return true;
    };
  });
  tearDown(() {
    clipboardWriter = savedClip;
    externalLinkLauncher = savedOpen;
  });

  group('onboarding: opsiyonel e-posta adımı', () {
    testWidgets('4. adım: adres + "Şimdi Kur" / "Daha Sonra Ayarlardan Kur"; sayaç baştan 1 / 4', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      var done = 0;
      await tester.pumpWidget(_app(OnboardingPage(
        controller: OnboardingController(store: _MemStore()),
        signUp: false,
        includeEmailStep: true,
        app: h.app,
        onDone: () => done++,
      )));
      expect(find.text('1 / 4'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('onb-primary')));
        await tester.pumpAndSettle();
      }
      expect(find.text('4 / 4'), findsOneWidget);
      expect(find.byKey(const ValueKey('onb-title-email')), findsOneWidget);
      expect(find.text('E-Faturaların Otomatik Gelsin mi?'), findsOneWidget);
      expect(find.byKey(const ValueKey('onb-skip')), findsNothing, reason: 'son adımda Atla yok');
      expect(find.byKey(const ValueKey('onb-primary')), findsNothing);
      expect(find.text(h.app.inbound!.address), findsOneWidget, reason: 'özel adres tanıtılır');
      expect(find.text('Şimdi Kur'), findsOneWidget);
      expect(find.text('Daha Sonra Ayarlardan Kur'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('onb-email-later')));
      await tester.pumpAndSettle();
      expect(done, 1, reason: 'onboarding tamamlandı');
      expect(find.byType(EmailSetupWizardPage), findsNothing);
    });

    testWidgets('"Şimdi Kur" sihirbazı açar; sihirbazdan dönünce onboarding tamamlanır', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      var done = 0;
      await tester.pumpWidget(_app(OnboardingPage(
        controller: OnboardingController(store: _MemStore()),
        signUp: false,
        includeEmailStep: true,
        app: h.app,
        onDone: () => done++,
      )));
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('onb-primary')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('onb-email-setup')));
      await tester.pump();
      await _flush(tester, h);
      await tester.pump(const Duration(milliseconds: 500)); // sayfa geçişi (bekleme göstergesi sonsuz animasyon: pumpAndSettle yok)
      expect(find.byType(EmailSetupWizardPage), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-address')), findsOneWidget);
      expect(done, 0);

      await tester.tap(find.text('Ayarlar')); // NavBackBar
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(EmailSetupWizardPage), findsNothing);
      expect(done, 1);
    });

    testWidgets('adımsız (genel rehber): 3 adım, son adımda "Başlayalım"; e-posta adımı yok', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(OnboardingPage(controller: OnboardingController(store: _MemStore()), signUp: false)));
      expect(find.text('1 / 3'), findsOneWidget);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const ValueKey('onb-primary')));
        await tester.pumpAndSettle();
      }
      expect(find.text('3 / 3'), findsOneWidget);
      expect(find.text('Başlayalım'), findsOneWidget);
      expect(find.text('Şimdi Kur'), findsNothing);
    });
  });

  group('AccountReadyPage: adımın varlığı sayfa açılmadan belirlenir', () {
    Future<void> run(WidgetTester tester, Harness h, String expectedCounter) async {
      await tester.pumpWidget(_app(AccountReadyPage(email: 'yeni@x.co', app: h.app, onboarding: OnboardingController(store: _MemStore()))));
      await tester.tap(find.text('Devam et'));
      await tester.pump();
      await _flush(tester, h);
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(find.text(expectedCounter), findsOneWidget);
    }

    testWidgets('senkron açık + sunucuda yapılandırılmış → 1 / 4', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      await run(tester, h, '1 / 4');
    });

    testWidgets('senkron KAPALI → adım atlanır (1 / 3)', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester, sync: false);
      await run(tester, h, '1 / 3');
    });

    testWidgets('sunucuda özellik kapalı → adım atlanır (1 / 3)', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester, inbound: false);
      await run(tester, h, '1 / 3');
    });
  });

  group('kurulum sihirbazı', () {
    testWidgets('Tam otomatik: adres/filtre kopyalanır; Gmail onay kodu canlı görünür, kopyalanır, bağlantı açılır; durum satırı', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(milliseconds: 100))));
      await _flush(tester, h);
      final address = h.app.inbound!.address;

      expect(find.byKey(const ValueKey('wiz-address')), findsOneWidget);
      expect(find.text(address), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-status')), findsOneWidget);
      expect(find.textContaining('Henüz e-posta alınmadı'), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-confirm-waiting')), findsOneWidget, reason: 'onay bekleniyor');

      await tester.tap(find.byKey(const ValueKey('wiz-copy-address')));
      await tester.pump();
      expect(copied, [address]);

      await tester.ensureVisible(find.byKey(const ValueKey('wiz-copy-filter')));
      await tester.tap(find.byKey(const ValueKey('wiz-copy-filter')));
      await tester.pump();
      expect(copied.last, 'subject:(fatura OR "e-arşiv" OR "e-fatura" OR "sipariş özeti" OR makbuz)');
      expect(copied.last, kGmailFilterQuery);

      // Google onay maili düştü: bir sonraki yoklamada "Onay Kodu Geldi" kartı canlı görünür.
      h.backend.user(_email).confirmation = {
        'code': '123456789',
        'link': 'https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-abc',
        'received_at': '2026-11-20T20:00:00Z',
      };
      await tester.pump(const Duration(milliseconds: 150));
      await _flush(tester, h);
      expect(find.byKey(const ValueKey('wiz-confirm-card')), findsOneWidget);
      expect(find.text('Onay Kodu Geldi: 123456789'), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-confirm-waiting')), findsNothing);

      await tester.ensureVisible(find.byKey(const ValueKey('wiz-copy-code')));
      await tester.tap(find.byKey(const ValueKey('wiz-copy-code')));
      await tester.pump();
      expect(copied.last, '123456789');
      await tester.tap(find.byKey(const ValueKey('wiz-open-link')));
      await tester.pump();
      expect(opened.single.toString(), 'https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-abc');

      // İlk e-posta işlendi: durum satırı "Aktif — Son aktarım".
      h.backend.user(_email).lastReceivedAt = '2026-11-20T20:05:00Z';
      await tester.pump(const Duration(milliseconds: 150));
      await _flush(tester, h);
      expect(find.textContaining('Aktif — Son aktarım:'), findsOneWidget);

      await tester.pumpWidget(const SizedBox()); // sihirbaz kapanır: yoklama zamanlayıcısı iptal
    });

    testWidgets('son webhook sonucu kullanıcıya söylenir: yok sayılan PDF/tutarsız mail "Aktif" satırında gizlenmez', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      final u = h.backend.user(_email);
      u.lastReceivedAt = '2026-11-20T20:05:00Z';
      u.lastStatus = 'ignored:pdf_unreadable';
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
      await _flush(tester, h);
      expect(find.textContaining('Aktif — Son aktarım:'), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-last-status')), findsOneWidget);
      expect(find.textContaining('PDF okunamadı'), findsOneWidget);
      expect(find.textContaining('Paylaş → Fissio'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    test('lastStatusMessage: bilinen durumlar Türkçe, bilinmeyen null', () {
      String? m(String? s) => emailLastStatusMessage(s);
      expect(m('created'), contains('fişe dönüştürüldü'));
      expect(m('merged'), contains('birleştirildi'));
      expect(m('duplicate_order'), contains('zaten kayıtlıydı'));
      expect(m('duplicate'), contains('zaten kayıtlıydı'));
      expect(m('ignored:no_amount'), contains('tutar bulunamadı'));
      expect(m('ignored:rate_limited'), contains('çok fazla'));
      expect(m('ignored:empty'), contains('okunamadı'));
      expect(m('gmail_confirmation'), contains('Gmail'));
      expect(m(null), isNull);
      expect(m(''), isNull);
      expect(m('bilinmeyen'), isNull);
    });

    testWidgets('bağlantısız onay (link yok): yalnızca kod; "Onay Bağlantısını Aç" görünmez', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      h.backend.user(_email).confirmation = {'code': '987654321', 'received_at': '2026-11-20T20:00:00Z'};
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(milliseconds: 100))));
      await _flush(tester, h);
      expect(find.text('Onay Kodu Geldi: 987654321'), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-open-link')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Kurulumsuz sekmesi: İlet (Forward) ve Paylaş → Fissio adımları', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
      await _flush(tester, h);
      await tester.tap(find.text('Kurulumsuz Hızlı Kullanım'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('wiz-forward')), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-share')), findsOneWidget);
      expect(find.textContaining('İlet (Forward)'), findsOneWidget);
      expect(find.textContaining('Paylaş'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('wiz-copy-address-2')));
      await tester.pump();
      expect(copied.single, h.app.inbound!.address);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('sihirbaz hesabı "Yeni" rozetini söndürür; aktarılan fişlerin profili aktif profile ayarlanır', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      expect(h.app.emailImportIsNew, isTrue);
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
      await _flush(tester, h);
      await _flush(tester, h);
      expect(h.app.emailImportIsNew, isFalse);
      expect(h.backend.user(_email).inboundProfileId, isNotNull, reason: 'aktif profil seçildi');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('adres yenile: onay → yeni adres', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
      await _flush(tester, h);
      final old = h.app.inbound!.address;
      await tester.ensureVisible(find.byKey(const ValueKey('wiz-rotate')));
      await tester.tap(find.byKey(const ValueKey('wiz-rotate')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Yenile'));
      await tester.pump();
      await _flush(tester, h);
      await tester.pump(const Duration(milliseconds: 500));
      expect(h.app.inbound!.address, isNot(old));
      expect(find.text(h.app.inbound!.address), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('senkron KAPALI: açıklama + Paylaş adımı; adres/onay yok', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester, sync: false);
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
      await _flush(tester, h);
      expect(find.byKey(const ValueKey('wiz-sync-off')), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-address')), findsNothing);
      expect(find.byKey(const ValueKey('wiz-share')), findsOneWidget);
      expect(h.backend.confirmationPolls, 0, reason: 'senkron kapalıyken sunucuya hiç gidilmez');
    });

    testWidgets('sunucuda özellik kapalı: bilgilendirme', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester, inbound: false);
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
      await _flush(tester, h);
      expect(find.byKey(const ValueKey('wiz-disabled')), findsOneWidget);
      expect(find.text('Bu sunucuda e-posta aktarımı kapalı'), findsOneWidget);
      expect(h.backend.confirmationPolls, 0);
    });
  });

  group('Ayarlar: iki bağımsız rehber girişi', () {
    testWidgets('"Uygulama Rehberi / Tanıtımı" 3 adımlı genel rehberi, e-posta satırı sihirbazı açar', (tester) async {
      _tall(tester);
      final ctrl = OnboardingController(store: _MemStore());
      await tester.pumpWidget(_app(SettingsPage(onboarding: ctrl)));
      await tester.pump();
      expect(find.text('Uygulama Rehberi / Tanıtımı'), findsOneWidget);
      expect(find.text('E-Posta ile Otomatik Fiş Aktarımı'), findsOneWidget);

      await tester.tap(find.text('Uygulama Rehberi / Tanıtımı'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget, reason: 'genel rehber e-posta adımını içermez');
      await tester.tap(find.byKey(const ValueKey('onb-skip')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('E-Posta ile Otomatik Fiş Aktarımı'));
      await tester.pumpAndSettle();
      expect(find.byType(EmailSetupWizardPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('"Yeni" rozeti: kullanılabilirken görünür, sihirbaz açılınca kaybolur', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      await tester.pumpWidget(_app(Scaffold(body: ListView(children: [EmailImportSettingsRow(app: h.app)]))));
      expect(find.byKey(const ValueKey('settings-email-new')), findsOneWidget);
      await h.app.markEmailImportSeen();
      await tester.pump();
      expect(find.byKey(const ValueKey('settings-email-new')), findsNothing);
      expect(find.text('E-Posta ile Otomatik Fiş Aktarımı'), findsOneWidget, reason: 'satır kalıcı');
    });
  });

  group('ana sayfa kartı', () {
    testWidgets('görünür, açılır, kapatılınca kalıcı olarak kaybolur', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      await tester.pumpWidget(_app(Scaffold(body: ListView(children: [EmailImportCard(app: h.app)]))));
      expect(find.byKey(const ValueKey('email-card')), findsOneWidget);
      expect(find.text('Yeni: E-Faturalarını Otomatik Aktar'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('email-card-dismiss')));
      await tester.pump();
      expect(find.byKey(const ValueKey('email-card')), findsNothing);
      expect(h.prefs.data['email_card_dismissed:${h.app.user!.id}'], '1');
      expect(h.app.showEmailImportCard, isFalse);
    });

    testWidgets('karta dokununca sihirbaz açılır', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      await tester.pumpWidget(_app(Scaffold(body: ListView(children: [EmailImportCard(app: h.app)]))));
      await tester.tap(find.byKey(const ValueKey('email-card-open')));
      await tester.pump();
      await _flush(tester, h);
      expect(find.byType(EmailSetupWizardPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('özellik tanıtıldıysa (onboarding e-posta adımı gösterildi) kart çıkmaz; yalnızca atlayan/mevcut kullanıcıda çıkar', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      await tester.pumpWidget(_app(OnboardingPage(
        controller: OnboardingController(store: _MemStore()),
        signUp: false,
        includeEmailStep: true,
        app: h.app,
        onDone: () {},
      )));
      expect(h.app.showEmailImportCard, isTrue, reason: 'adım henüz görülmedi');
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('onb-primary')));
        await tester.pumpAndSettle();
      }
      expect(find.text('4 / 4'), findsOneWidget);
      expect(h.app.showEmailImportCard, isFalse, reason: 'adım gösterildi → ana sayfada ikinci tanıtım yok');
      expect(h.app.emailImportIsNew, isFalse);
    });

    testWidgets('senkron kapalıyken ya da sunucuda özellik kapalıyken görünmez', (tester) async {
      _tall(tester);
      final off = await _signedIn(tester, sync: false);
      await tester.pumpWidget(_app(Scaffold(body: ListView(children: [EmailImportCard(app: off.app)]))));
      expect(find.byKey(const ValueKey('email-card')), findsNothing);
      final disabled = await _signedIn(tester, inbound: false);
      await tester.pumpWidget(_app(Scaffold(body: ListView(children: [EmailImportCard(app: disabled.app)]))));
      expect(find.byKey(const ValueKey('email-card')), findsNothing);
    });
  });
}
