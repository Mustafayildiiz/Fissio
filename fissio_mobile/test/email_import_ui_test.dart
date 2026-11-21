import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/app_info.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/ocr/ocr_engine.dart' show ocrEngineDisplayName;
import 'package:fissio_mobile/onboarding_controller.dart';
import 'package:fissio_mobile/pages/account_ready_page.dart';
import 'package:fissio_mobile/pages/email_import_card.dart';
import 'package:fissio_mobile/pages/email_setup_wizard.dart';
import 'package:fissio_mobile/pages/onboarding_page.dart';
import 'package:fissio_mobile/pages/receipt_detail_page.dart';
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
      expect(
        copied.last,
        '(fatura OR "e-arşiv" OR "e-fatura" OR "e-arsiv" OR fiş OR sipariş OR makbuz OR ödeme OR bilet) -bülten -kampanya -indirim',
      );
      expect(copied.last, kGmailFilterQuery);
      for (var i = 1; i <= 5; i++) {
        expect(find.byKey(ValueKey('wiz-filter-step-$i')), findsOneWidget, reason: 'adım adım Gmail filtre rehberi');
      }

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

    for (final entry in <String, Map<String, dynamic>>{
      'code alanı yok': {'link': 'https://mail-settings.google.com/mail/vf-%5BA%5D-only', 'received_at': '2026-11-20T20:00:00Z'},
      'code null': {'code': null, 'link': 'https://mail-settings.google.com/mail/vf-%5BA%5D-only', 'received_at': '2026-11-20T20:00:00Z'},
      'code boş string': {'code': '', 'link': 'https://mail-settings.google.com/mail/vf-%5BA%5D-only', 'received_at': '2026-11-20T20:00:00Z'},
    }.entries) {
      testWidgets('kodsuz onay (${entry.key}) + link: çökmez, "Gmail Yönlendirmesini Onayla" tıklanır', (tester) async {
        _tall(tester);
        final h = await _signedIn(tester);
        h.backend.user(_email).confirmation = entry.value;
        await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(milliseconds: 100))));
        await _flush(tester, h);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('wiz-confirm-card')), findsOneWidget);
        expect(find.byKey(const ValueKey('wiz-confirm-code')), findsNothing);
        expect(find.byKey(const ValueKey('wiz-copy-code')), findsNothing);
        expect(find.textContaining('Onay Kodu Geldi'), findsNothing);
        expect(find.text('Gmail Yönlendirmesini Onayla'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('wiz-open-link')));
        await tester.tap(find.byKey(const ValueKey('wiz-open-link')));
        await tester.pump();
        expect(opened.single.toString(), 'https://mail-settings.google.com/mail/vf-%5BA%5D-only');
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('ne kod ne link: kart çökmeden açıklama gösterir', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      h.backend.user(_email).confirmation = {'received_at': '2026-11-20T20:00:00Z'};
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(milliseconds: 100))));
      await _flush(tester, h);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('wiz-confirm-empty')), findsOneWidget);
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

  group('aktarım geçmişi: Son Aktarılan E-Postalar', () {
    Map<String, dynamic> row(int id, String status, {String? reason, int? expenseId, String subject = 'Konu'}) => {
          'id': id,
          'source': 'email',
          'from': 'ABLUKA <earsiv@abluka.example>',
          'subject': '$subject $id',
          'received_at': '2026-11-20T20:0$id:00Z',
          'status': status,
          'reason': ?reason,
          'expense_id': ?expenseId,
        };

    testWidgets('boş durum, rozetler (Kaydedildi / Tutar Bulunamadı / Hata / Zaten Kayıtlı) ve konu/tarih görünür', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
      await _flush(tester, h);
      await tester.ensureVisible(find.byKey(const ValueKey('wiz-history')));
      expect(find.text('SON AKTARILAN E-POSTALAR'), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-history-empty')), findsOneWidget);

      h.backend.user(_email).inboundHistory = [
        row(4, 'failed', reason: 'db_error'),
        row(3, 'ignored', reason: 'no_amount'),
        row(2, 'ignored', reason: 'duplicate_order', expenseId: 7),
        row(1, 'saved', reason: 'created', expenseId: 7),
      ];
      h.backend.user(_email).lastReceivedAt = '2026-11-20T20:05:00Z'; // yoklama yeni aktarımı fark edip geçmişi yeniler
      await tester.pump(const Duration(seconds: 31)); // 30 sn'lik yoklama: son aktarım zamanı değişti → geçmiş yeniden çekilir
      await _flush(tester, h);
      await tester.pump();

      expect(find.byKey(const ValueKey('wiz-history-empty')), findsNothing);
      for (final t in ['Kaydedildi', 'Tutar Bulunamadı', 'Hata', 'Zaten Kayıtlı']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('Konu 1'), findsOneWidget);
      expect(find.textContaining('20.11.2026'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('kaydedilen satıra dokununca ilgili fişin detay sayfası açılır; hatalı satır dokunulamaz', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      late int expenseId;
      await tester.runAsync(() async {
        await h.app.saveDraft(ReceiptDraft(merchant: 'ABLUKA Teknoloji', categoryId: 1, items: [ExpenseItem('Bulut Depolama', 10, categoryId: 1)]));
        expenseId = h.app.expenses.first.id;
      });
      h.backend.user(_email).inboundHistory = [
        row(2, 'ignored', reason: 'no_amount'),
        row(1, 'saved', reason: 'created', expenseId: expenseId),
      ];
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
      await _flush(tester, h);

      await tester.ensureVisible(find.byKey(const ValueKey('wiz-history-1')));
      // Not: sihirbaz açıkken pumpAndSettle KULLANILMAZ (onay bekleme göstergesi sonsuz animasyon).
      await tester.tap(find.byKey(const ValueKey('wiz-history-2')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ReceiptDetailPage), findsNothing, reason: 'fişi olmayan satır gezinmez');

      await tester.tap(find.byKey(const ValueKey('wiz-history-1')));
      await tester.pump(const Duration(milliseconds: 100));
      await _flush(tester, h);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ReceiptDetailPage), findsOneWidget);
      expect(find.text('ABLUKA Teknoloji'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('yok sayılan mail: üst kart (son aktarım + durum) ve geçmiş AYNI yoklamada güncellenir', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(milliseconds: 100))));
      await _flush(tester, h);
      expect(find.textContaining('Henüz e-posta alınmadı'), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-history-empty')), findsOneWidget);

      final u = h.backend.user(_email);
      u.lastReceivedAt = '2026-11-21T14:30:00Z';
      u.lastStatus = 'ignored:no_amount';
      u.inboundHistory = [row(1, 'ignored', reason: 'no_amount')];
      await tester.pump(const Duration(milliseconds: 150));
      await _flush(tester, h);
      await tester.pump();

      expect(find.textContaining('Aktif — Son aktarım:'), findsOneWidget, reason: 'üst kart son aktarım tarihini gösterir');
      expect(find.byKey(const ValueKey('wiz-last-status')), findsOneWidget);
      expect(find.textContaining('tutar bulunamadı'), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-history-empty')), findsNothing);
      expect(find.text('Tutar Bulunamadı'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('failed satırı gerçek nedeni gösterir; üst kart hata durumunu söyler', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      final u = h.backend.user(_email);
      u.lastReceivedAt = '2026-11-21T14:30:00Z';
      u.lastStatus = 'failed:db_error';
      u.inboundHistory = [row(7, 'failed', reason: 'db_error: pq: new row violates check constraint "boom"')];
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
      await _flush(tester, h);
      await tester.ensureVisible(find.byKey(const ValueKey('wiz-history-7')));
      expect(find.text('Hata'), findsOneWidget);
      expect(find.byKey(const ValueKey('wiz-history-reason-7')), findsOneWidget);
      expect(find.textContaining('check constraint "boom"'), findsOneWidget);
      expect(find.textContaining('işlenirken bir hata oluştu'), findsOneWidget);
      expect(emailLastStatusMessage('failed:db_error'), isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    test('emailHistoryBadge eşlemesi', () {
      InboundHistoryItem it(String s, [String? r]) => InboundHistoryItem(id: 1, status: s, reason: r);
      expect(emailHistoryBadge(it('saved', 'merged')).label, 'Kaydedildi');
      expect(emailHistoryBadge(it('failed', 'db_error')).error, isTrue);
      expect(emailHistoryBadge(it('ignored', 'pdf_unreadable')).label, 'PDF Okunamadı');
      expect(emailHistoryBadge(it('ignored', 'rate_limited')).warn, isTrue);
      expect(emailHistoryBadge(it('ignored', 'unknown_category')).label, 'Atlandı');
      expect(ocrEngineDisplayName('xml'), 'e-Fatura XML (UBL-TR)', reason: 'sunucunun yazdığı xml motoru detayda etiketli');
      expect(InboundHistoryItem.fromJson({'id': 3, 'status': 'saved', 'expense_id': 9}).hasExpense, isTrue);
      expect(InboundHistoryItem.fromJson({'id': 3, 'status': 'ignored'}).hasExpense, isFalse);
    });

    testWidgets('senkron kapalıyken geçmiş istenmez (sunucuya istek yok)', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester, sync: false);
      await tester.pumpWidget(_app(EmailSetupWizardPage(app: h.app, pollInterval: const Duration(seconds: 30))));
      await _flush(tester, h);
      expect(h.backend.historyPolls, 0);
      expect(find.byKey(const ValueKey('wiz-history')), findsNothing);
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
      expect(find.text('1 / 3'), findsOneWidget, reason: 'giriş yapılmamış / özellik kullanılamıyor: e-posta adımı yok');
      await tester.tap(find.byKey(const ValueKey('onb-skip')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('E-Posta ile Otomatik Fiş Aktarımı'));
      await tester.pumpAndSettle();
      expect(find.byType(EmailSetupWizardPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('e-posta aktarımı kullanılabilirken Ayarlar rehberi 4 adımdır ve 4. adım e-posta özelliğini anlatır', (tester) async {
      _tall(tester);
      final h = await _signedIn(tester);
      final ctrl = OnboardingController(store: _MemStore());
      await tester.pumpWidget(_app(SettingsPage(onboarding: ctrl, inboundApp: h.app)));
      await tester.pump();

      await tester.tap(find.text('Uygulama Rehberi / Tanıtımı'));
      await _flush(tester, h);
      await tester.pumpAndSettle();
      expect(find.text('1 / 4'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('onb-primary')));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('onb-title-email')), findsOneWidget);
      expect(find.text('E-Faturaların Otomatik Gelsin mi?'), findsOneWidget);
      expect(find.byKey(const ValueKey('onb-email-address')), findsOneWidget);

      // "Daha Sonra Ayarlardan Kur": rehber doğrudan Ayarlar'a döner.
      await tester.tap(find.byKey(const ValueKey('onb-email-later')));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingPage), findsNothing);
      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('sıralama: E-Posta ile Fiş Aktarımı satırı Tercihler ile Veri Yönetimi arasındadır', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(const SettingsPage()));
      await tester.pump();
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('Tercihler'), lessThan(y('E-Posta ile Otomatik Fiş Aktarımı')));
      expect(y('E-Posta ile Otomatik Fiş Aktarımı'), lessThan(y('Veri Yönetimi')));
      expect(y('Veri Yönetimi'), lessThan(y('Uygulama Rehberi / Tanıtımı')));
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
