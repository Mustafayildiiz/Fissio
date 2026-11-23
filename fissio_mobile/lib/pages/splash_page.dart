import 'package:flutter/material.dart';
import '../api.dart';
import '../app_state.dart';
import '../logo.dart';
import '../services/deep_links.dart';
import '../theme.dart';
import '../widgets.dart';
import 'auth_page.dart';
import 'profile_select_page.dart';
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
    // Widget kısayolu (soğuk açılış) oturum geri yüklenirken okunur.
    final restore = deepLinks.init().then((_) => appState.restoreSession());
    // Splash en az 1,2 sn görünür; ama widget'tan "hızlı tara" ile açıldıysa kamerayı geciktirmemek için beklenmez.
    final minDelay = Future<void>.delayed(const Duration(milliseconds: 1200));
    final ok = await restore;
    if (!deepLinks.hasPendingAction) await minDelay;
    if (!mounted) return;
    // Hızlı tara + oturum var ama aktif profil seçili değilse (ilk açılış / silinmiş profil) ilk profili seç:
    // kullanıcı profil seçiciye düşmeden doğrudan kameraya gitsin.
    if (ok && deepLinks.hasPendingAction && appState.activeProfile == null && appState.profiles.isNotEmpty) {
      try {
        await appState.selectProfile(appState.profiles.first);
      } on ApiException {
        // Seçilemedi (ağ/sunucu): splash'te takılı kalma; aşağıda profil seçicisine düşülür.
      }
      if (!mounted) return;
    }
    // Widget'tan "hızlı tara" ile açıldıysa ve aktif profil varsa profil seçimi atlanır; kabuk taramayı açar.
    final direct = ok && deepLinks.hasPendingAction && appState.activeProfile != null;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => direct
            ? const ShellPage()
            : ok
            ? const ProfileSelectPage()
            : const AuthPage(),
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
              const FissioLogo(size: 88),
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
