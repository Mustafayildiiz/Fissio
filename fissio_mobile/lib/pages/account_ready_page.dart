import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../onboarding_controller.dart';
import '../theme.dart';
import '../widgets.dart';
import 'account_widgets.dart';
import 'onboarding_page.dart';
import 'profile_select_page.dart';

/// Doğrulama sonrası "Hesap hazır" (tasarım 1e). İlk profil ("Kişisel") sunucuda otomatik oluşturulur;
/// profil seçiminde kendi profillerini ekleyip yönetebilir. İlk kayıtta tanıtım (onboarding) gösterilir.
class AccountReadyPage extends StatelessWidget {
  const AccountReadyPage({super.key, this.email, this.app, this.onboarding});
  final String? email;

  /// Verilmezse global [onboardingController] (testlerde sahte depolu denetleyici verilir).
  final OnboardingController? onboarding;

  /// Verilmezse global [appState].
  final AppState? app;

  Future<void> _continue(BuildContext context) async {
    final a = app ?? appState;
    final showOnboarding = await (onboarding ?? onboardingController).shouldShowAfterSignUp(email);
    // E-posta adımı: yalnızca bulut senkronu açık ve sunucuda özellik yapılandırılmışsa. Karar sayfa AÇILMADAN verilir (adım
    // sayacı akış boyunca sabit kalır); aynı çağrı kullanıcının yönlendirme adresini de (yoksa) üretir.
    var emailStep = false;
    if (showOnboarding) {
      await a.loadInbound();
      emailStep = a.emailImportAvailable;
    }
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => showOnboarding
            ? OnboardingPage(controller: onboarding, email: email, includeEmailStep: emailStep, app: app)
            : const ProfileSelectPage(),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 36),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                  child: Icon(LucideIcons.check, size: 42, color: c.onAccent),
                ),
              ),
              const SizedBox(height: 18),
              Text('Hesabın hazır', style: FissioText.title(c, size: 40).copyWith(height: 1.05)),
              const Rule2(margin: EdgeInsets.symmetric(vertical: 18)),
              Text(
                'E-posta adresin doğrulandı. "Kişisel" profilin oluşturuldu; istersen Ev, İş gibi yeni profiller ekleyebilirsin.',
                style: FissioText.body(c, size: 17, color: c.mute).copyWith(height: 1.45),
              ),
              const Spacer(),
              ArrowButton(label: 'Devam et', onPressed: () => _continue(context)),
            ],
          ),
        ),
      ),
    );
  }
}
