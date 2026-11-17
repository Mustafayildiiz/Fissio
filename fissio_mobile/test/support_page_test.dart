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

    expect(find.text('Fissio · Sürüm 2.3.4 (7)'), findsOneWidget);
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

  testWidgets('Hakkımızda/Gizlilik bölümleri çizilir', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(InfoPage(title: 'Gizlilik Politikası', sections: InfoTexts.privacy)));
    expect(find.text('Haklarınız (KVKK / GDPR)', skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(_app(InfoPage(title: 'Hakkımızda', sections: InfoTexts.about)));
    expect(find.text('Bulut ve çevrimdışı kullanım', skipOffstage: false), findsOneWidget);
  });
}
