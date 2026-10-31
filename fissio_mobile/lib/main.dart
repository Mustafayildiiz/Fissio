import 'package:flutter/material.dart';

import 'app_state.dart';
import 'pages/auth_page.dart';
import 'pages/splash_page.dart';
import 'theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  runApp(const FissioApp());
}

class FissioApp extends StatefulWidget {
  const FissioApp({super.key});

  @override
  State<FissioApp> createState() => _FissioAppState();
}

class _FissioAppState extends State<FissioApp> {
  @override
  void initState() {
    super.initState();
    // Token süresi dolduğunda (401) girişe dön.
    appState.onSessionExpired = () {
      navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AuthPage()),
        (_) => false,
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fissio',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: buildTheme(),
      home: const SplashPage(),
    );
  }
}
