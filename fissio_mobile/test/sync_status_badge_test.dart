import 'package:fissio_mobile/pages/sync_status_badge.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Başlıktaki minimal durum rozeti: senkron kapalı → nötr yerel ikon; senkron açık + çevrimdışı → çevrimdışı ikonu
/// (dokununca açıklama); senkron açık + çevrimiçi → gizli. Büyük çevrimdışı bandı artık yok.
Widget _host(Harness h) => MaterialApp(
  theme: buildTheme(brightness: Brightness.light),
  home: Scaffold(body: Center(child: SyncStatusBadge(app: h.app))),
);

const _local = Key('sync-status-badge-local');
const _offline = Key('sync-status-badge-offline');

void main() {
  testWidgets('senkron açık + çevrimiçi: rozet gizli', (tester) async {
    late Harness h;
    await tester.runAsync(() async {
      h = Harness();
      await h.signIn('ali@x.co');
    });
    await tester.pumpWidget(_host(h));
    expect(find.byKey(_local), findsNothing);
    expect(find.byKey(_offline), findsNothing);
  });

  testWidgets('senkron açık + çevrimdışı: ikon görünür, dokununca açıklama çıkar; bağlantı gelince kaybolur', (tester) async {
    late Harness h;
    await tester.runAsync(() async {
      h = Harness();
      await h.signIn('ali@x.co');
    });
    await tester.pumpWidget(_host(h));

    h.connectivity.emit(false);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    expect(h.app.connected, isFalse);
    expect(find.byKey(_offline), findsOneWidget);

    await tester.tap(find.byKey(_offline));
    await tester.pumpAndSettle();
    expect(find.text('Çevrimdışısın'), findsOneWidget);
    expect(find.textContaining('Bağlantı yok'), findsWidgets);
    await tester.tapAt(const Offset(5, 5)); // sheet'i kapat
    await tester.pumpAndSettle();

    h.connectivity.emit(true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(h.app.connected, isTrue);
    expect(find.byKey(_offline), findsNothing);
  });

  testWidgets('senkron kapalı: çevrimdışı olsa da uyarı yok, yalnızca nötr yerel ikon', (tester) async {
    late Harness h;
    await tester.runAsync(() async {
      h = Harness();
      await h.signIn('ali@x.co');
      await h.app.setSyncEnabled(false);
    });
    await tester.pumpWidget(_host(h));
    expect(find.byKey(_local), findsOneWidget);
    expect(find.byKey(_offline), findsNothing);

    h.connectivity.emit(false);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    expect(find.byKey(_local), findsOneWidget);
    expect(find.byKey(_offline), findsNothing);
    expect(find.textContaining('Çevrimdışısın'), findsNothing);
  });
}
