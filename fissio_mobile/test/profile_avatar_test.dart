import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/profile_avatar.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: buildTheme(brightness: Brightness.light, accent: kDefaultAccent),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('fotoğraf yokken baş harfler çizilir', (tester) async {
    await tester.pumpWidget(_app(const ProfileAvatarView(
      name: 'Mustafa Yıldız',
      profile: Profile(id: 'p', name: 'Kişisel'),
      size: 60,
    )));
    expect(find.text('MY'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('profil null ise de baş harf; dokunma çalışır', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(ProfileAvatarView(name: 'Ev', onTap: () => taps++)));
    expect(find.text('E'), findsOneWidget);
    await tester.tap(find.text('E'));
    expect(taps, 1);
  });
}
