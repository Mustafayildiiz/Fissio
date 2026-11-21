import 'package:fissio_mobile/pages/preferences_page.dart';
import 'package:fissio_mobile/pages/profile_edit_page.dart';
import 'package:fissio_mobile/pages/settings_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

Widget _wrap(Widget child) => MaterialApp(theme: buildTheme(), home: child);

void main() {
  group('Ayarlar: tek profil akışı', () {
    testWidgets('çift "Profil değiştir" satırı yok; karta dokununca sheet: değiştir (+ düzenle)', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(const SettingsPage()));
      await tester.pump();
      expect(find.text('Profil değiştir'), findsNothing, reason: 'sayfada ayrı satır kalmadı');
      expect(find.byKey(const ValueKey('change-avatar')), findsNothing);
      expect(find.text('Profil fotoğrafını değiştir'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('settings-profile-card')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profile-switch')), findsOneWidget);
      expect(find.text('Profil değiştir'), findsOneWidget);
    });
  });

  group('Profili düzenle', () {
    testWidgets('ad satırı diyaloğu açar ve yeni adı kaydeder (aktif profil güncellenir)', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = Harness();
      await tester.runAsync(() => h.signIn('ali@x.co'));
      final old = h.app.activeProfile!.name;
      await tester.pumpWidget(_wrap(ProfileEditPage(app: h.app)));
      await tester.pump();
      expect(find.text(old), findsWidgets);
      expect(find.byKey(const ValueKey('edit-avatar')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('edit-name')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'İş Harcamaları');
      await tester.runAsync(() async {
        await tester.tap(find.text('Kaydet'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(h.app.activeProfile!.name, 'İş Harcamaları');
      expect(find.text('İş Harcamaları'), findsWidgets);
    });

    testWidgets('bulut senkronu kapalıyken ad satırı devre dışı ve nedeni yazılı', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = Harness();
      await tester.runAsync(() async {
        await h.signIn('ali@x.co');
        await h.app.setSyncEnabled(false);
      });
      await tester.pumpWidget(_wrap(ProfileEditPage(app: h.app)));
      await tester.pump();
      expect(find.textContaining('bulut senkronu açık olmalı'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('edit-name')));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing, reason: 'diyalog açılmaz, kayıt hatası da yok');
      expect(find.text('Profili yeniden adlandır'), findsNothing);
    });

    testWidgets('avatar dokunuşu fotoğraf seçeneklerini açar', (tester) async {
      final h = Harness();
      await tester.runAsync(() => h.signIn('ali@x.co'));
      await tester.pumpWidget(_wrap(ProfileEditPage(app: h.app)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('edit-avatar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('avatar-camera')), findsOneWidget);
      expect(find.byKey(const ValueKey('avatar-gallery')), findsOneWidget);
    });
  });

  group('Tercihler grupları', () {
    testWidgets('üç ana başlık sırayla ve ilgili kontroller doğru grupta', (tester) async {
      tester.view.physicalSize = const Size(900, 4200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(const PreferencesPage()));
      await tester.pump();
      double y(Finder f) => tester.getTopLeft(f).dy;
      final look = find.byKey(const ValueKey('prefs-group-Görünüm ve Tema'));
      final scan = find.byKey(const ValueKey('prefs-group-Tarama ve OCR Motoru'));
      final general = find.byKey(const ValueKey('prefs-group-Bildirimler ve Genel'));
      expect(look, findsOneWidget);
      expect(y(look), lessThan(y(scan)));
      expect(y(scan), lessThan(y(general)));

      expect(y(find.byKey(const ValueKey('widget-theme'))), allOf(greaterThan(y(look)), lessThan(y(scan))));
      expect(y(find.byKey(const ValueKey('ocr-mode'))), allOf(greaterThan(y(scan)), lessThan(y(general))));
      expect(y(find.byKey(const ValueKey('show-ocr-engine-switch'))), lessThan(y(general)));
      expect(y(find.byKey(const ValueKey('home-layout-row'))), greaterThan(y(general)));
      expect(find.byKey(const ValueKey('prefs-notifications-note')), findsOneWidget);
    });
  });
}
