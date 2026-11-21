import 'dart:async';

import 'package:fissio_mobile/pages/home_layout_page.dart';
import 'package:fissio_mobile/pages/home_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemStore implements PrefsStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

Widget _wrap(Widget child) => MaterialApp(theme: buildTheme(), home: Scaffold(body: child));

// SectionLabel metni Dart'ın toUpperCase'iyle büyütür (Türkçe i/İ yok): beklenen değerler aynı yoldan üretilir.
final kCats = 'Kategoriler'.toUpperCase();
final kTop = 'En yüksek fiş'.toUpperCase();
final kTotal = 'Toplam harcama'.toUpperCase();

double _y(WidgetTester t, String text) => t.getTopLeft(find.text(text)).dy;

void main() {
  // Global denetleyicinin gerçek güvenli depolaması testte yanıt vermez: durum notifyListeners ile anında değişir,
  // yazma beklenmez (unawaited).
  tearDown(() => unawaited(themeController.resetHomeCards()));

  group('Özet görünümünü özelleştir sayfası', () {
    testWidgets('anahtar kartı gizler/gösterir; oklar sırayı değiştirir; varsayılana döndür', (tester) async {
      final ctl = ThemeController(store: _MemStore());
      await tester.pumpWidget(_wrap(HomeLayoutPage(controller: ctl)));
      for (final c in HomeCard.values) {
        expect(find.byKey(ValueKey('home-layout-card-${c.name}')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('home-layout-reset')), findsNothing, reason: 'varsayılanken gerek yok');

      await tester.tap(find.byKey(const ValueKey('home-layout-switch-budgets')));
      await tester.pump();
      expect(ctl.hiddenHomeCards, {HomeCard.budgets});
      expect(tester.widget<Switch>(find.byKey(const ValueKey('home-layout-switch-budgets'))).value, isFalse);

      await tester.tap(find.byKey(const ValueKey('home-layout-down-categories')));
      await tester.pump();
      expect(ctl.homeCardOrder.first, HomeCard.budgets);
      expect(ctl.homeCardOrder[1], HomeCard.categories);
      await tester.tap(find.byKey(const ValueKey('home-layout-up-topReceipt')));
      await tester.pump();
      expect(ctl.homeCardOrder.indexOf(HomeCard.topReceipt), HomeCard.values.length - 2);

      // İlk satırın "yukarı", son satırın "aşağı" düğmesi devre dışı.
      final first = ctl.homeCardOrder.first.name, last = ctl.homeCardOrder.last.name;
      expect(tester.widget<IconButton>(find.byKey(ValueKey('home-layout-up-$first'))).onPressed, isNull);
      expect(tester.widget<IconButton>(find.byKey(ValueKey('home-layout-down-$last'))).onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('home-layout-reset')));
      await tester.pump();
      expect(ctl.homeCardOrder, HomeCard.values);
      expect(ctl.hiddenHomeCards, isEmpty);
    });
  });

  group('Özet ekranı', () {
    testWidgets('sıra değişince kartlar yeni sırada, gizlenen yok; kısayol yalnız gizli kart varken görünür', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(HomePage(onOpenCategory: (_) {})));
      await tester.pump();
      expect(_y(tester, kCats), lessThan(_y(tester, kTop)));
      expect(find.byKey(const ValueKey('home-hidden-cards')), findsNothing);

      unawaited(themeController.setHomeCardOrder([HomeCard.topReceipt, HomeCard.categories, HomeCard.budgets, HomeCard.fixed]));
      await tester.pump();
      expect(_y(tester, kTop), lessThan(_y(tester, kCats)), reason: 'sıra anında uygulanır (const çocuk tuzağı yok)');

      unawaited(themeController.setHomeCardHidden(HomeCard.topReceipt, true));
      await tester.pump();
      expect(find.text(kTop), findsNothing);
      expect(find.text(kCats), findsOneWidget);
      expect(find.text('Gizlenen kartları yönet (1)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('home-hidden-cards')));
      await tester.pumpAndSettle();
      expect(find.byType(HomeLayoutPage), findsOneWidget);
    });

    testWidgets('hepsi gizliyken toplam bloğu ve kısayol kalır, çökme/kopukluk yok', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final c in HomeCard.values) {
        unawaited(themeController.setHomeCardHidden(c, true));
      }
      await tester.pumpWidget(_wrap(HomePage(onOpenCategory: (_) {})));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text(kCats), findsNothing);
      expect(find.text(kTotal), findsOneWidget);
      expect(find.text('Gizlenen kartları yönet (${HomeCard.values.length})'), findsOneWidget);
    });
  });
}
