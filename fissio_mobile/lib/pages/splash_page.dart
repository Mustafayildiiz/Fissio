import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'auth_page.dart';
import 'shell_page.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final results = await Future.wait<Object?>([
      appState.restoreSession(),
      Future<void>.delayed(const Duration(milliseconds: 1200)),
    ]);
    if (!mounted) return;
    final ok = results[0] as bool;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ok ? const ShellPage() : const AuthPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: const BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: 16),
            const Text('Fissio', style: TextStyle(color: Colors.white, fontSize: 36)),
            const SizedBox(height: 10),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 36),
              child: Text(
                'Fişleri tarayın, manuel kaydedin ve harcamalarınızı tek ekranda takip edin.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

