import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/app_state.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/shell_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gerçek cihazda yakalanan hata: ShellPage.initState içinde başlatılan yenileme `loading=true` bildirimini build
/// sırasında yayıyor ve "setState() called during build" atıyordu.
void main() {
  testWidgets('ShellPage açılışta yenilemeyi build sırasında başlatmaz (setState-during-build yok)', (tester) async {
    // Oturum açık ve yenileme bayat: kabuk açılışında gerçek bir yenileme başlar (testte HTTP 400 döner).
    appState.user = const AuthUser(id: 7, email: 'a@b.co');
    appState.api.setTokens(
      AuthTokens(access: 'a', refresh: 'r', expiresAt: DateTime.now().add(const Duration(hours: 1))),
      notify: false,
    );
    addTearDown(() {
      appState.api.setTokens(null, notify: false);
      appState.user = null;
    });
    // Uygulamada ShellPage'den ÖNCE kurulan bir appState dinleyicisi var (ör. ana sayfa dışı üst bileşenler): ağacın
    // önceki bir dalındaki dinleyici build sırasında kirletilirse framework assertion atar.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Column(
            children: [
              ListenableBuilder(listenable: appState, builder: (_, _) => Text('loading=${appState.loading}')),
              const Expanded(child: ShellPage()),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: 'initState içinde senkron notifyListeners yok');
  });
}
