import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/toast.dart';
import 'package:fissio_mobile/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Üst bildirim (toast): ekranın ÜSTÜNDE belirir, alt gezinmeyi kapatmaz, dokunarak/kaydırarak ya da süre dolunca kapanır.

Widget _app({required void Function(BuildContext) onTap}) => MaterialApp(
      theme: buildTheme(brightness: Brightness.light, accent: kDefaultAccent),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(child: ElevatedButton(key: const ValueKey('go'), onPressed: () => onTap(context), child: const Text('göster'))),
          bottomNavigationBar: const SizedBox(key: ValueKey('bottom-bar'), height: 64, child: Text('ALT BAR')),
        ),
      ),
    );

Future<void> _show(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('go')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('toast ekranın üstünde görünür ve alt çubuğu kapatmaz', (tester) async {
    await tester.pumpWidget(_app(onTap: (c) => showMessage(c, 'Fiş kaydedildi')));
    await _show(tester);

    final toast = find.byKey(const ValueKey('app-toast'));
    expect(find.text('Fiş kaydedildi'), findsOneWidget);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getTopLeft(toast).dy, lessThan(screen.height / 4), reason: 'üstte');
    expect(tester.getBottomLeft(toast).dy, lessThan(screen.height / 2));
    // Alt çubuk görünür ve toast ile kesişmez.
    expect(find.text('ALT BAR'), findsOneWidget);
    expect(tester.getRect(toast).overlaps(tester.getRect(find.byKey(const ValueKey('bottom-bar')))), isFalse);
    expect(find.byType(SnackBar), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('süre dolunca kendiliğinden kapanır', (tester) async {
    await tester.pumpWidget(_app(onTap: (c) => showMessage(c, 'Geçici')));
    await _show(tester);
    expect(find.text('Geçici'), findsOneWidget);
    await tester.pump(kToastDuration);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Geçici'), findsNothing);
  });

  testWidgets('dokununca kapanır', (tester) async {
    await tester.pumpWidget(_app(onTap: (c) => showMessage(c, 'Dokun')));
    await _show(tester);
    await tester.tap(find.text('Dokun'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Dokun'), findsNothing);
  });

  testWidgets('yukarı kaydırınca kapanır', (tester) async {
    await tester.pumpWidget(_app(onTap: (c) => showMessage(c, 'Kaydır')));
    await _show(tester);
    await tester.fling(find.byKey(const ValueKey('app-toast')), const Offset(0, -200), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Kaydır'), findsNothing);
  });

  testWidgets('yeni toast eskisinin yerine geçer; hata türü ve eylem butonu çalışır', (tester) async {
    var acted = 0;
    await tester.pumpWidget(_app(onTap: (c) {
      showMessage(c, 'Birinci');
      showToast(c, 'İkinci', kind: ToastKind.error, actionLabel: 'Kopyala', onAction: () => acted++);
    }));
    await _show(tester);
    expect(find.text('Birinci'), findsNothing);
    expect(find.text('İkinci'), findsOneWidget);
    expect(find.byKey(const ValueKey('app-toast')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app-toast-action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(acted, 1);
    expect(find.text('İkinci'), findsNothing);
  });

  testWidgets('showError üst toast olarak mesajı gösterir', (tester) async {
    await tester.pumpWidget(_app(onTap: (c) => showError(c, 'Sunucu hatası')));
    await _show(tester);
    expect(find.text('Sunucu hatası'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
