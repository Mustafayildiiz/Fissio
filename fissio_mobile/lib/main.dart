import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'onboarding_controller.dart';
import 'pages/auth_page.dart';
import 'pages/splash_page.dart';
import 'theme.dart';
import 'theme_controller.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // İlk kareler doğru tema/vurgu ile çizilsin diye tercihler runApp'ten önce yüklenir.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await Future.wait([themeController.load(), onboardingController.load()]);
  runApp(const FissioApp());
}

class FissioApp extends StatefulWidget {
  const FissioApp({super.key});

  @override
  State<FissioApp> createState() => _FissioAppState();
}

class _FissioAppState extends State<FissioApp> with WidgetsBindingObserver {
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Uygulama ön plana gelince token'ı önceden yenile ve çevrimdışı kuyruğu boşalt.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) appState.onAppResumed();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Token süresi dolduğunda (401) giriş sayfasına dön.
    appState.onSessionExpired = () {
      navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AuthPage()),
        (_) => false,
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeController,
      builder: (context, _) => MaterialApp(
        title: 'Fissio',
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        theme: buildTheme(accent: themeController.accent),
        darkTheme: buildTheme(
          brightness: Brightness.dark,
          accent: themeController.accent,
        ),
        themeMode: themeController.themeMode,
        builder: (context, child) {
          final dark = Theme.of(context).brightness == Brightness.dark;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarContrastEnforced: false,
              statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
              systemNavigationBarIconBrightness:
                  dark ? Brightness.light : Brightness.dark,
            ),
            child: child!,
          );
        },
        home: const SplashPage(),
      ),
    );
  }
}
