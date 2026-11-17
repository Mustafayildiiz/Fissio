import 'dart:convert';
import 'dart:typed_data';

import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/data/file_transfer.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/account_widgets.dart';
import 'package:fissio_mobile/pages/auth_page.dart';
import 'package:fissio_mobile/pages/data_management_page.dart';
import 'package:fissio_mobile/pages/forgot_password_page.dart';
import 'package:fissio_mobile/pages/sessions_page.dart';
import 'package:fissio_mobile/pages/verify_email_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

Widget _app(Widget home, {Brightness brightness = Brightness.light}) =>
    MaterialApp(theme: buildTheme(brightness: brightness), home: home);

/// Dar telefon ekranı (360x740): taşma (overflow) testleri için.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 2, 740 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

Future<void> _enterCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const Key('otp-input')), code);
  await tester.pump();
}

void main() {
  group('şifre kuralları', () {
    test('güç ve geçerlilik', () {
      expect(PasswordRules.of('abc').valid, isFalse);
      expect(PasswordRules.of('abcdefgh').valid, isFalse, reason: 'rakam ve büyük harf yok');
      expect(PasswordRules.of('Abcdefg1').valid, isTrue);
      expect(PasswordRules.of('Abcdefg1').label, 'İyi');
      expect(PasswordRules.of('Abcdef1!').label, 'Güçlü');
      expect(PasswordRules.of('abc').label, 'Zayıf');
      expect(PasswordRules.of('ŞifreTest1').valid, isTrue, reason: 'Türkçe büyük harf');
      expect(PasswordRules.of('A1${'x' * 80}').valid, isFalse, reason: 'bcrypt 72 bayt sınırı');
    });
  });

  group('E-posta doğrulama ekranı', () {
    testWidgets('geri sayım işler; süre dolunca "Kodu tekrar gönder" açılır ve yeni geri sayım başlar', (tester) async {
      _phone(tester);
      var resent = 0;
      await tester.pumpWidget(_app(VerifyEmailPage(
        email: 'ali@x.co',
        initialCooldown: 3,
        onVerify: (e, c) async {},
        onResend: (e) async {
          resent++;
          return 60;
        },
        onSuccess: () {},
      )));
      expect(find.text('0:03'), findsOneWidget);
      expect(find.text('ali@x.co'), findsNothing, reason: 'e-posta zengin metnin içinde');
      expect(find.textContaining('6 haneli bir kod gönderdik', findRichText: true), findsOneWidget);

      // Geri sayım sürerken "tekrar gönder" etkisiz.
      await tester.tap(find.text('Kodu tekrar gönder'));
      await tester.pump();
      expect(resent, 0);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:02'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('otp-countdown')), findsNothing);

      await tester.tap(find.text('Kodu tekrar gönder'));
      await tester.pump();
      await tester.pump();
      expect(resent, 1);
      expect(find.text('1:00'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:59'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('6 hane girilince otomatik doğrular; başarıda onSuccess çağrılır', (tester) async {
      _phone(tester);
      String? got;
      var ok = 0;
      await tester.pumpWidget(_app(VerifyEmailPage(
        email: 'ali@x.co',
        onVerify: (e, c) async => got = '$e|$c',
        onSuccess: () => ok++,
      )));
      await _enterCode(tester, '12345');
      expect(got, isNull, reason: '5 hane yetmez');
      await _enterCode(tester, '123456');
      await tester.pump();
      expect(got, 'ali@x.co|123456');
      expect(ok, 1);
    });

    testWidgets('hatalı kod ve süresi dolmuş kod uyarıları gösterilir, alan temizlenir', (tester) async {
      _phone(tester);
      var attempt = 0;
      await tester.pumpWidget(_app(VerifyEmailPage(
        email: 'ali@x.co',
        onVerify: (e, c) async {
          attempt++;
          if (attempt == 1) throw ApiException('Kod hatalı. Tekrar deneyin.', status: 400, code: 'invalid_code');
          if (attempt == 2) throw ApiException('Kodun süresi doldu. Yeni kod isteyin.', status: 400, code: 'code_expired');
          throw ApiException('Çok fazla hatalı deneme. Yeni kod isteyin.', status: 429, code: 'too_many_attempts');
        },
        onSuccess: () {},
      )));
      await _enterCode(tester, '111111');
      await tester.pump();
      expect(find.text('Kod hatalı. Tekrar deneyin.'), findsOneWidget);
      expect((tester.widget<TextField>(find.byKey(const Key('otp-input'))).controller!).text, isEmpty);

      await _enterCode(tester, '222222');
      await tester.pump();
      expect(find.text('Kodun süresi doldu. Yeni kod isteyin.'), findsOneWidget);

      await _enterCode(tester, '333333');
      await tester.pump();
      expect(find.text('Çok fazla hatalı deneme. Yeni kod isteyin.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sunucu cooldown döndürürse kalan süre geri sayıma yansır', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(VerifyEmailPage(
        email: 'ali@x.co',
        initialCooldown: 0,
        onVerify: (e, c) async {},
        onResend: (e) async => throw ApiException('Yeni kod için biraz bekleyin.', status: 429, code: 'resend_cooldown', retryAfter: 17),
        onSuccess: () {},
      )));
      await tester.tap(find.text('Kodu tekrar gönder'));
      await tester.pump();
      await tester.pump();
      expect(find.text('0:17'), findsOneWidget);
      expect(find.text('Yeni kod için biraz bekleyin.'), findsOneWidget);
    });
  });

  group('Şifremi unuttum (kodla)', () {
    testWidgets('e-posta -> kod gönderilir -> kod + yeni şifre -> başarıda true ile kapanır', (tester) async {
      tester.view.physicalSize = const Size(360 * 2, 1400 * 2); // tüm adım ekranda
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      String? sentTo;
      List<String>? reset;
      bool? result;
      await tester.pumpWidget(_app(Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await Navigator.of(ctx).push<bool>(MaterialPageRoute(
              builder: (_) => ForgotPasswordPage(
                onSend: (e) async {
                  sentTo = e;
                  return 60;
                },
                onReset: (e, c, p) async => reset = [e, c, p],
              ),
            )),
            child: const Text('aç'),
          ),
        ),
      )));
      await tester.tap(find.text('aç'));
      await tester.pumpAndSettle();

      // Geçersiz e-posta
      await tester.tap(find.text('Kod gönder'));
      await tester.pump();
      expect(find.text('Geçerli bir e-posta girin.'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'ali@x.co');
      await tester.tap(find.text('Kod gönder'));
      await tester.pump();
      await tester.pump();
      expect(sentTo, 'ali@x.co');
      expect(find.text('Yeni şifre belirle'), findsOneWidget);
      expect(find.text('1:00'), findsOneWidget);

      // Zayıf şifre / eşleşmeyen şifre reddedilir.
      await tester.enterText(find.byKey(const Key('otp-input')), '654321');
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), 'zayif');
      await tester.enterText(fields.at(2), 'zayif');
      await tester.tap(find.text('Şifreyi güncelle'));
      await tester.pump();
      expect(find.byKey(const Key('reset-error')), findsOneWidget);
      expect(reset, isNull);
      await tester.enterText(fields.at(1), 'YeniSifre1');
      await tester.enterText(fields.at(2), 'YeniSifre2');
      await tester.tap(find.text('Şifreyi güncelle'));
      await tester.pump();
      expect(find.text('Şifreler eşleşmiyor.'), findsOneWidget);

      await tester.enterText(fields.at(2), 'YeniSifre1');
      await tester.tap(find.text('Şifreyi güncelle'));
      await tester.pumpAndSettle();
      expect(reset, ['ali@x.co', '654321', 'YeniSifre1']);
      expect(result, isTrue);
    });
  });

  group('Giriş / Kayıt ekranı', () {
    testWidgets('kayıt doğrulamaları: e-posta, şifre kuralları, tekrar, şartlar', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const AuthPage(startInRegister: true)));
      expect(find.text('Hesap oluştur'), findsWidgets);
      expect(find.text('Ad soyad'), findsOneWidget);
      expect(find.text('Şifre tekrar'), findsOneWidget);
      expect(find.text('En az 8 karakter'), findsOneWidget);

      Future<void> submit() async {
        await tester.ensureVisible(find.byType(ArrowButton));
        await tester.tap(find.byType(ArrowButton));
        await tester.pump();
      }

      await submit();
      expect(find.text('Geçerli bir e-posta girin.'), findsOneWidget);

      final f = find.byType(TextField);
      await tester.enterText(f.at(1), 'ali@x.co');
      await tester.enterText(f.at(2), 'kisa');
      await submit();
      expect(find.textContaining('en az 8 karakter olmalı'), findsOneWidget);

      await tester.enterText(f.at(2), 'GucluSifre1');
      await tester.enterText(f.at(3), 'GucluSifre2');
      await submit();
      expect(find.text('Şifreler eşleşmiyor.'), findsWidgets);

      await tester.enterText(f.at(3), 'GucluSifre1');
      await submit();
      expect(find.textContaining('kabul edin'), findsOneWidget, reason: 'şartlar onayı zorunlu');
      expect(tester.takeException(), isNull);
    });

    testWidgets('giriş ekranında "Şifremi unuttum" ve hesap oluştur geçişi var', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const AuthPage()));
      expect(find.text('Şifremi unuttum'), findsOneWidget);
      expect(find.text('Hesabın yok mu?'), findsOneWidget);
      await tester.tap(find.text('Hesap oluştur'));
      await tester.pump();
      expect(find.text('Ad soyad'), findsOneWidget);
      expect(find.text('Zaten hesabın var mı?'), findsOneWidget);
    });
  });

  group('Aktif oturumlar', () {
    testWidgets('cihazlar listelenir, "Bu cihaz" işaretlenir, tek oturum uzaktan kapatılır', (tester) async {
      _phone(tester);
      var sessions = [
        DeviceSession(id: 'a', deviceName: 'Pixel 8', platform: 'android', lastActiveAt: DateTime.now(), createdAt: DateTime.now(), current: true),
        DeviceSession(id: 'b', deviceName: 'iPhone 15', platform: 'ios', lastActiveAt: DateTime.now().subtract(const Duration(hours: 5)), createdAt: DateTime.now(), current: false),
      ];
      String? revoked;
      await tester.pumpWidget(_app(SessionsPage(
        loader: () async => sessions,
        onRevoke: (id) async {
          revoked = id;
          sessions = sessions.where((s) => s.id != id).toList();
        },
      )));
      await tester.pumpAndSettle();
      expect(find.text('Pixel 8'), findsOneWidget);
      expect(find.text('iPhone 15'), findsOneWidget);
      expect(find.textContaining('Bu cihaz'), findsOneWidget);
      expect(find.text('Tüm cihazlardan çıkış yap'), findsOneWidget);

      await tester.tap(find.text('Kapat').last);
      await tester.pumpAndSettle();
      expect(find.text('Oturumu kapat'), findsOneWidget);
      await tester.tap(find.text('Kapat').last);
      await tester.pumpAndSettle();
      expect(revoked, 'b');
      expect(find.text('iPhone 15'), findsNothing);
    });

    testWidgets('"Tüm cihazlardan çıkış yap" onay ister ve çağrılır', (tester) async {
      _phone(tester);
      var called = 0;
      await tester.pumpWidget(_app(SessionsPage(
        loader: () async => [
          DeviceSession(id: 'a', deviceName: 'Pixel 8', platform: 'android', lastActiveAt: DateTime.now(), createdAt: DateTime.now(), current: true),
        ],
        onLogoutAll: () async => called++,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tüm cihazlardan çıkış yap'));
      await tester.pumpAndSettle();
      expect(find.textContaining('tüm cihazlardaki oturumlar kapatılır'), findsOneWidget);
      await tester.tap(find.text('Çıkış yap'));
      await tester.pump();
      await tester.pump();
      expect(called, 1);
    });
  });

  group('Veri Yönetimi', () {
    late Harness h;
    late _FakeTransfer transfer;

    Future<void> open(WidgetTester tester) async {
      // Sahte sunucu gerçek asenkron bölgede hazırlanır (FakeAsync içinde zamanlayıcılar ilerlemez).
      await tester.runAsync(() async {
        h = Harness();
        transfer = _FakeTransfer();
        await h.signIn('ali@x.co');
        await h.app.saveDraft(ReceiptDraft(merchant: 'BIM', categoryId: 1, items: [ExpenseItem('Süt', 10, categoryId: 1)]));
        await h.app.saveDraft(ReceiptDraft(merchant: 'Migros', categoryId: 1, items: [ExpenseItem('Ekmek', 5)]));
      });
      _phone(tester);
      await tester.pumpWidget(_app(DataManagementPage(
        app: h.app,
        transfer: transfer,
        now: () => DateTime(2026, 5, 20),
      )));
      await tester.pump();
    }

    testWidgets('JSON ve CSV dışa aktarma dosyası oluşturur ve paylaşır', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('export-json')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paylaş…'));
      await tester.pumpAndSettle();
      expect(transfer.shared.single.name, 'fissio-yedek-2026-05-20.json');
      final json = parseJson(transfer.shared.single.bytes);
      expect(json['format'], 'fissio-backup');
      expect(((json['profiles'] as List).first as Map)['expenses'], hasLength(2));

      await tester.tap(find.byKey(const Key('export-csv')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cihaza kaydet'));
      await tester.pumpAndSettle();
      expect(transfer.saved.single.name, 'fissio-yedek-2026-05-20.csv');
      final raw = transfer.saved.single.bytes;
      expect(raw.take(3), [0xEF, 0xBB, 0xBF], reason: 'Excel için UTF-8 BOM');
      final csv = utf8.decode(raw);
      expect(csv, contains('profil;'));
      expect(csv, contains('BIM'));
    });

    testWidgets('içe aktarma: biçim doğrulanır, yedek geri yüklenirken mükerrer eklenmez', (tester) async {
      await open(tester);
      // Önce dışa aktar, sonra aynı dosyayı seç.
      await tester.tap(find.byKey(const Key('export-json')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paylaş…'));
      await tester.pumpAndSettle();
      transfer.pick = (name: 'yedek.json', text: utf8.decode(transfer.shared.single.bytes));

      await tester.tap(find.byKey(const Key('import')));
      await tester.pumpAndSettle();
      expect(find.text('Yedek yüklensin mi?'), findsOneWidget);
      await tester.tap(find.text('Yükle'));
      await tester.pumpAndSettle();
      expect(find.text('İçe aktarma tamamlandı'), findsOneWidget);
      expect(find.textContaining('0 fiş eklendi'), findsOneWidget);
      expect(find.textContaining('2 fiş zaten vardı'), findsOneWidget);
      await tester.tap(find.text('Tamam'));
      await tester.pumpAndSettle();
      expect(h.app.allExpenses, hasLength(2));

      // Bozuk dosya: anlaşılır hata, hiçbir şey eklenmez.
      transfer.pick = (name: 'x.json', text: '{"foo": 1}');
      await tester.tap(find.byKey(const Key('import')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Fissio yedeği değil'), findsOneWidget);
      expect(h.app.allExpenses, hasLength(2));
    });

    testWidgets('senkron anahtarı varsayılan açık; kapatırken uyarı çıkar ve onayla kapanır, tekrar açılır', (tester) async {
      await open(tester);
      Switch sw() => tester.widget<Switch>(find.byKey(const Key('sync-switch')));
      expect(sw().value, isTrue, reason: 'varsayılan: bulut kaydı açık');

      await tester.tap(find.byKey(const Key('sync-switch')));
      await tester.pumpAndSettle();
      expect(find.text('Bulut senkronu kapatılsın mı?'), findsOneWidget);
      // Vazgeç: değişmez.
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(h.app.syncEnabled, isTrue);

      await tester.tap(find.byKey(const Key('sync-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kapat'));
      await tester.pumpAndSettle();
      expect(h.app.syncEnabled, isFalse);
      expect(sw().value, isFalse);

      await tester.tap(find.byKey(const Key('sync-switch')));
      await tester.pumpAndSettle();
      expect(h.app.syncEnabled, isTrue);
      await tester.runAsync(() => h.settle(20));
    });
  });
}

Map<String, dynamic> parseJson(Uint8List b) => jsonDecode(utf8.decode(b)) as Map<String, dynamic>;

class _FakeTransfer implements FileTransfer {
  final shared = <({String name, Uint8List bytes})>[];
  final saved = <({String name, Uint8List bytes})>[];
  ({String name, String text})? pick;

  @override
  Future<void> share({required String filename, required Uint8List bytes, required String mimeType}) async =>
      shared.add((name: filename, bytes: bytes));

  @override
  Future<bool> saveToDevice({required String filename, required Uint8List bytes, required String mimeType}) async {
    saved.add((name: filename, bytes: bytes));
    return true;
  }

  @override
  Future<({String name, String text})?> pickBackup() async => pick;
}
