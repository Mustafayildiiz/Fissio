import 'package:fissio_mobile/pages/account_widgets.dart';
import 'package:fissio_mobile/pages/auth_page.dart';
import 'package:fissio_mobile/pages/info_page.dart';
import 'package:fissio_mobile/pages/legal_consent_sheet.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget home) => MaterialApp(theme: buildTheme(brightness: Brightness.light), home: home);

/// Telefon ekranı (390x844).
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

const _accept = ValueKey('legal-accept');

bool _checked(WidgetTester tester, String key) => tester.widget<AccentCheck>(find.byKey(ValueKey(key))).value;

VoidCallback? _acceptAction(WidgetTester tester) => tester.widget<ArrowButton>(find.byKey(_accept)).onPressed;

ScrollPosition _sheetScroll(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byKey(const ValueKey('legal-scroll')), matching: find.byType(Scrollable)))
    .position;

/// Onay kutusunun kendisine (sol üstteki kare) dokunur; ortası bağlantı metnine denk gelebilir.
Future<void> _tapBox(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tapAt(tester.getTopLeft(f) + const Offset(15, 19));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  group('Kayıt ekranı yasal onay penceresi', () {
    testWidgets('Kullanım Şartları: kaydırmadan buton pasif, en alta kaydırınca aktif ve onay kutusunu işaretler',
        (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const AuthPage(startInRegister: true)));
      expect(_checked(tester, 'terms-check'), isFalse);

      await _tapVisible(tester, find.byKey(const ValueKey('terms-link')));
      expect(find.byType(LegalConsentSheet), findsOneWidget);
      expect(find.text(InfoTexts.termsTitle), findsWidgets);

      // Ön koşul: metin ekrana sığmıyor (yoksa "pasif" iddiası bir şey test etmez).
      expect(_sheetScroll(tester).maxScrollExtent, greaterThan(0));
      expect(_acceptAction(tester), isNull, reason: 'metin okunmadan buton pasif');
      expect(find.byKey(const ValueKey('legal-scroll-hint')), findsOneWidget);

      // Pasif butona dokunmak hiçbir şey yapmaz.
      await tester.tap(find.byKey(_accept), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(LegalConsentSheet), findsOneWidget);

      // Yarıya kadar kaydırmak yetmez.
      await tester.drag(find.byKey(const ValueKey('legal-scroll')), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(_sheetScroll(tester).pixels, greaterThan(0));
      expect(_acceptAction(tester), isNull);

      // En alta kaydırınca aktif olur.
      await tester.drag(find.byKey(const ValueKey('legal-scroll')), const Offset(0, -30000));
      await tester.pumpAndSettle();
      expect(_acceptAction(tester), isNotNull);
      expect(find.byKey(const ValueKey('legal-scroll-hint')), findsNothing);

      await tester.tap(find.byKey(_accept));
      await tester.pumpAndSettle();
      expect(find.byType(LegalConsentSheet), findsNothing);
      expect(_checked(tester, 'terms-check'), isTrue);
      expect(_checked(tester, 'privacy-check'), isFalse, reason: 'yalnızca ilgili kutu işaretlenir');
      expect(tester.takeException(), isNull);
    });

    testWidgets('işaretsiz kutuya dokunmak metni açar; kapatılırsa kutu işaretsiz kalır; işaretli kutu kaldırılabilir',
        (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const AuthPage(startInRegister: true)));

      await _tapBox(tester, 'privacy-check');
      expect(find.byType(LegalConsentSheet), findsOneWidget);
      expect(find.text(InfoTexts.privacyTitle), findsWidgets);
      expect(_sheetScroll(tester).maxScrollExtent, greaterThan(0));
      expect(_acceptAction(tester), isNull);

      await tester.tap(find.byKey(const ValueKey('legal-close')));
      await tester.pumpAndSettle();
      expect(find.byType(LegalConsentSheet), findsNothing);
      expect(_checked(tester, 'privacy-check'), isFalse, reason: 'okumadan işaretlenemez');

      // Bağlantıdan aç, sona kaydır, kabul et.
      await _tapVisible(tester, find.byKey(const ValueKey('privacy-link')));
      await tester.drag(find.byKey(const ValueKey('legal-scroll')), const Offset(0, -40000));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_accept));
      await tester.pumpAndSettle();
      expect(_checked(tester, 'privacy-check'), isTrue);

      // İşaretli kutuya dokunmak işareti kaldırır (pencere açılmaz).
      await _tapBox(tester, 'privacy-check');
      expect(find.byType(LegalConsentSheet), findsNothing);
      expect(_checked(tester, 'privacy-check'), isFalse);
    });

    testWidgets('yalnız bir metin kabul edilmişse kayıt "kabul edin" hatası verir', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const AuthPage(startInRegister: true)));
      final f = find.byType(TextField);
      await tester.enterText(f.at(1), 'ali@x.co');
      await tester.enterText(f.at(2), 'GucluSifre1');
      await tester.enterText(f.at(3), 'GucluSifre1');

      await _tapVisible(tester, find.byKey(const ValueKey('terms-link')));
      await tester.drag(find.byKey(const ValueKey('legal-scroll')), const Offset(0, -40000));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_accept));
      await tester.pumpAndSettle();
      expect(_checked(tester, 'terms-check'), isTrue);

      await _tapVisible(tester, find.byType(ArrowButton));
      expect(find.textContaining('kabul edin'), findsOneWidget);
    });

    testWidgets('metin ekrana sığıyorsa buton kaydırmadan aktiftir', (tester) async {
      _phone(tester);
      bool? result;
      await tester.pumpWidget(_app(Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => result = await showLegalConsent(
                context,
                title: 'Kısa metin',
                sections: const [InfoSection('Başlık', 'Tek satırlık kısa bir metin.')],
              ),
              child: const Text('aç'),
            ),
          ),
        ),
      )));
      await tester.tap(find.text('aç'));
      await tester.pumpAndSettle();
      expect(_sheetScroll(tester).maxScrollExtent, 0);
      expect(_acceptAction(tester), isNotNull);
      expect(find.byKey(const ValueKey('legal-scroll-hint')), findsNothing);
      await tester.tap(find.byKey(_accept));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });
  });
}
