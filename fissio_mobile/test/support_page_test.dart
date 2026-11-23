import 'package:fissio_mobile/app_info.dart';
import 'package:fissio_mobile/pages/info_page.dart';
import 'package:fissio_mobile/pages/support_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget home) =>
    MaterialApp(theme: buildTheme(brightness: Brightness.light, accent: kDefaultAccent), home: home);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  final origVersion = appVersionLoader;
  final origMail = mailLauncher;
  final origClip = clipboardWriter;
  tearDown(() {
    appVersionLoader = origVersion;
    mailLauncher = origMail;
    clipboardWriter = origClip;
  });

  testWidgets('sürüm, e-posta ve SSS gösterilir; SSS açılır', (tester) async {
    _tall(tester);
    appVersionLoader = () async => '2.3.4 (7)';
    await tester.pumpWidget(_app(const SupportPage()));
    await tester.pumpAndSettle();

    expect(find.text('Fissio · Sürüm 2.3.4 (7)', skipOffstage: false), findsOneWidget);
    expect(find.text(supportEmail), findsOneWidget);
    expect(find.text('İnternet yokken fiş ekleyebilir miyim?'), findsOneWidget);
    await tester.tap(find.text('İnternet yokken fiş ekleyebilir miyim?'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cihaz içi OCR'), findsOneWidget);
  });

  testWidgets('"Destek ekibine yaz" mailto açar; açılamazsa adres kopyalanır', (tester) async {
    _tall(tester);
    appVersionLoader = () async => '1.0.0';
    Uri? opened;
    String? copied;
    mailLauncher = (u) async {
      opened = u;
      return true;
    };
    clipboardWriter = (t) async => copied = t;
    await tester.pumpWidget(_app(const SupportPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('support-mail')));
    await tester.pumpAndSettle();
    expect(opened?.scheme, 'mailto');
    expect(opened?.path, supportEmail);
    expect(copied, isNull);

    mailLauncher = (u) async => false;
    await tester.tap(find.byKey(const ValueKey('support-mail')));
    await tester.pumpAndSettle();
    expect(copied, supportEmail);
  });

  testWidgets('SSS e-posta aktarımının olumsuz senaryolarını ve çözümlerini içerir', (tester) async {
    tester.view.physicalSize = const Size(900, 7000); // tüm SSS gövdeleri (tembel ListView) çizilsin
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_app(const SupportPage()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('support-email-faqs'), skipOffstage: false), findsOneWidget);
    const titles = [
      'Gmail yönlendirme onay maili gelmedi / kod görünmüyor.',
      'Mail gönderildi ama "Tutar Bulunamadı" göründü.',
      'Aynı fatura iki kez gelirse ne olur?',
      'Yabancı para birimli (USD/EUR) veya desteklenmeyen faturalar.',
      'Adresim spam listesine düştü ya da gereksiz reklam mailleri geliyor.',
      'E-posta aktarımını tamamen kapatmak istiyorum.',
      'Gönderim 5.7.1 / "teslim edilemedi" hatası aldım.',
    ];
    for (final t in titles) {
      await tester.ensureVisible(find.text(t));
      expect(find.text(t), findsOneWidget, reason: t);
    }
    Future<void> open(String title, String expectInBody) async {
      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.textContaining(expectInBody, skipOffstage: false), findsOneWidget, reason: title);
    }

    await open(titles[0], 'Adresi Yenile');
    await open(titles[1], 'Paylaş → Fissio');
    await open(titles[2], 'Zaten Kayıtlı');
    await open(titles[3], 'yalnızca TL');
    await open(titles[4], 'Aktarımı duraklat');
    await open(titles[5], 'Yönlendirme ve POP/IMAP');
    await open(titles[6], 'güvenlik politikası');
  });

  testWidgets('Hakkımızda/Gizlilik bölümleri çizilir', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(InfoPage(title: 'Gizlilik Politikası', sections: InfoTexts.privacy)));
    expect(find.text('Haklarınız (KVKK / GDPR)', skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(_app(InfoPage(title: 'Hakkımızda', sections: InfoTexts.about)));
    expect(find.text('Bulut ve çevrimdışı kullanım', skipOffstage: false), findsOneWidget);
  });

  testWidgets('yasal metinler e-posta ile fiş aktarımını kapsar (@fissio.dev, amaç sınırı, saklananlar)', (tester) async {
    String all(List<InfoSection> s) => s.map((e) => '${e.heading}\n${e.body}').join('\n');
    final privacy = all(InfoTexts.privacy);
    expect(InfoTexts.privacy.map((s) => s.heading), contains('E-posta ile fiş aktarımı'));
    expect(privacy, contains('@fissio.dev'));
    expect(privacy, contains('YALNIZCA fiş/fatura'));
    expect(privacy, contains('Son Aktarılan E-Postalar'));
    expect(InfoTexts.terms.map((s) => s.heading), contains('E-posta yönlendirme'));
    expect(InfoTexts.about.map((s) => s.heading), contains('E-posta ile otomatik fiş aktarımı'));
    expect(all(InfoTexts.about), contains('UBL-TR'));
    _tall(tester);
    await tester.pumpWidget(_app(InfoPage(title: 'Gizlilik Politikası', sections: InfoTexts.privacy)));
    expect(find.text('E-posta ile fiş aktarımı', skipOffstage: false), findsOneWidget);
  });
}
