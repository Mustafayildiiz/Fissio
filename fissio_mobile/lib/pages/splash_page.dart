import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'auth_page.dart';
import 'profile_select_page.dart';

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
      MaterialPageRoute(
        builder: (_) => ok ? const ProfileSelectPage() : const AuthPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 72),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: c.accent,
                  borderRadius: BorderRadius.circular(kRadius),
                ),
                child: Icon(LucideIcons.receipt, size: 36, color: c.onAccent),
              ),
              const SizedBox(height: 20),
              Text('Fissio', style: FissioText.title(c, size: 64).copyWith(height: 1)),
              const SizedBox(height: 20),
              const Rule2(margin: EdgeInsets.zero),
              const SizedBox(height: 20),
              Text(
                'Fişleri tarayın, manuel kaydedin ve harcamalarınızı tek ekranda takip edin.',
                style: FissioText.body(c, size: 18, color: c.mute).copyWith(height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
