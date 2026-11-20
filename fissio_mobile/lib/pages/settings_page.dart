import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../dialogs.dart';
import '../onboarding_controller.dart';
import '../logo.dart';
import '../theme.dart';
import '../widgets.dart';
import '../profile_avatar.dart';
import 'account_widgets.dart';
import 'avatar_picker.dart';
import 'auth_page.dart';
import 'data_management_page.dart';
import 'info_page.dart';
import 'onboarding_page.dart';
import '../app_info.dart';
import 'preferences_page.dart';
import 'profile_select_page.dart';
import 'sessions_page.dart';
import 'sync_status_badge.dart';
import 'support_page.dart';

/// Ayarlar'ı alttan açılan tam ekran sayfa olarak gösterir ("Bitti" ile kapanır).
void openSettings(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => const SettingsPage()),
  );
}

/// Başlık satırındaki aktif profil avatarı; dokununca Ayarlar açılır.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SyncStatusBadge(),
          ProfileAvatarView(
            name: appState.displayName,
            profile: appState.activeProfile,
            onTap: () => openSettings(context),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.onboarding});

  /// Verilmezse global [onboardingController] (testlerde sahte depolu denetleyici verilir).
  final OnboardingController? onboarding;

  /// Tanıtımı açar; bitince/kapatınca Ayarlar'a döner, satır görünür kalır.
  void _openOnboarding(BuildContext context, OnboardingController ctrl) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OnboardingPage(controller: ctrl, signUp: false),
      ),
    );
  }

  void _open(BuildContext context, String title, List<InfoSection> sections) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InfoPage(title: title, sections: sections, showLogo: title == 'Hakkımızda'),
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _toAuth(BuildContext context) {
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthPage()),
      (_) => false,
    );
  }

  /// Çıkış: bellekteki tüm hesap verisi, aktif profil ve token'lar silinir. Yüklenmemiş yerel kayıt varsa
  /// önce bilgilendirilir (cihazda kalır, aynı hesapla girişte geri gelir).
  Future<void> _logout(BuildContext context) async {
    final unsynced = appState.pendingCount + appState.localOnlyCount;
    final ok = await showConfirmDialog(
      context,
      title: 'Çıkış yap',
      message: unsynced > 0
          ? 'Buluta yüklenmemiş $unsynced kayıt bu cihazda saklanır ve aynı hesapla tekrar girince geri gelir. '
                'Önce Veri Yönetimi\'nden senkronlayabilir ya da dışa aktarabilirsin.'
          : 'Bu cihazdaki oturumun kapatılacak.',
      confirmLabel: 'Çıkış yap',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await appState.logout();
    if (context.mounted) _toAuth(context);
  }

  /// KVKK/GDPR: hesabı, profilleri, fişleri, görselleri ve oturumları kalıcı siler (şifre onayıyla).
  Future<void> _deleteAccount(BuildContext context) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Hesabını kalıcı olarak sil',
      message: 'Hesabın, tüm profillerin, fişlerin, fiş fotoğrafların ve açık oturumların sunucudan ve bu cihazdan '
          'kalıcı olarak silinir. Bu işlem geri alınamaz.',
      confirmLabel: 'Devam',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final pw = await showPasswordPrompt(
      context,
      title: 'Şifreni onayla',
      message: 'Silme işlemini onaylamak için şifreni gir.',
      confirmLabel: 'Hesabı sil',
      destructive: true,
    );
    if (pw == null || pw.isEmpty || !context.mounted) return;
    try {
      await appState.deleteAccount(pw);
      if (context.mounted) _toAuth(context);
    } on ApiException catch (e) {
      if (context.mounted) {
        showMessage(context, e.code == 'invalid_credentials' ? 'Şifre hatalı.' : e.message);
      }
    }
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String title,
    VoidCallback onTap,
  ) =>
      ListRow(
        leading: IconTile(icon, size: 30, radius: 8),
        title: title,
        chevron: true,
        vertical: 10,
        onTap: onTap,
      );

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final onb = onboarding ?? onboardingController;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([appState, onb]),
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TopBar(trailing: BarAction('Bitti', bold: true, onTap: () => Navigator.maybePop(context))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text('Ayarlar', style: FissioText.title(c)),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                  children: [
                    GroupedCard(
                      children: [
                        InkWell(
                          onTap: () => _push(context, const ProfileSelectPage()),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: Row(
                              children: [
                                ProfileAvatarView(
                                  name: appState.displayName,
                                  profile: appState.activeProfile,
                                  size: 60,
                                  filled: true,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        appState.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: FissioText.title(c, size: 20),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Aktif profil',
                                        style: FissioText.body(c, size: 14, color: c.mute),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(LucideIcons.chevronRight, size: 16, color: c.mute),
                              ],
                            ),
                          ),
                        ),
                        if (appState.activeProfile != null)
                          ListRow(
                            key: const ValueKey('change-avatar'),
                            leading: Icon(LucideIcons.camera, size: 20, color: c.accentInk),
                            title: 'Profil fotoğrafını değiştir',
                            titleColor: c.accentInk,
                            onTap: () => changeProfileAvatar(context, appState.activeProfile!),
                          ),
                        ListRow(
                          leading: Icon(LucideIcons.repeat, size: 20, color: c.accentInk),
                          title: 'Profil değiştir',
                          titleColor: c.accentInk,
                          onTap: () => _push(context, const ProfileSelectPage()),
                        ),
                      ],
                    ),
                    const Rule2(margin: EdgeInsets.fromLTRB(0, 14, 0, 6)),
                    GroupedCard(
                      children: [
                        _row(context, LucideIcons.slidersHorizontal, 'Tercihler',
                            () => _push(context, const PreferencesPage())),
                        _row(context, LucideIcons.database, 'Veri Yönetimi',
                            () => _push(context, const DataManagementPage())),
                      ],
                    ),
                    const SizedBox(height: 12),
                    GroupedCard(
                      children: [
                        _row(context, LucideIcons.bookOpen, 'Tanıtım Rehberini Görüntüle',
                            () => _openOnboarding(context, onb)),
                        _row(context, LucideIcons.lifeBuoy, 'Destek',
                            () => _push(context, const SupportPage())),
                        _row(context, LucideIcons.info, 'Hakkımızda',
                            () => _open(context, 'Hakkımızda', InfoTexts.about)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    GroupedCard(
                      children: [
                        _row(context, LucideIcons.shieldCheck, 'Gizlilik Politikası',
                            () => _open(context, 'Gizlilik Politikası', InfoTexts.privacy)),
                        _row(context, LucideIcons.fileText, 'Kullanım Şartları',
                            () => _open(context, 'Kullanım Şartları', InfoTexts.terms)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const SectionLabel('Hesap'),
                    GroupedCard(
                      children: [
                        if (appState.email != null)
                          ListRow(
                            leading: ProfileAvatarView(
                              key: const ValueKey('account-avatar'),
                              name: appState.displayName,
                              profile: appState.activeProfile,
                              size: 34,
                              filled: true,
                            ),
                            title: appState.email!,
                            subtitle: 'Giriş yapılan hesap',
                          ),
                        _row(context, LucideIcons.smartphone, 'Aktif oturumlar',
                            () => _push(context, const SessionsPage())),
                        _row(context, LucideIcons.logOut, 'Çıkış yap', () => _logout(context)),
                        ListRow(
                          leading: IconTile(LucideIcons.trash2, size: 34, radius: 10),
                          title: 'Hesabımı kalıcı olarak sil',
                          titleColor: c.danger,
                          vertical: 10,
                          onTap: () => _deleteAccount(context),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 18, 4, 0),
                      child: FutureBuilder<String>(
                        future: appVersionLoader(),
                        builder: (context, snap) => Row(
                          children: [
                            const FissioLogo(size: 22),
                            const SizedBox(width: 8),
                            Text(
                              (snap.data ?? '').isEmpty ? 'Fissio' : 'Fissio · Sürüm ${snap.data}',
                              style: FissioText.body(c, size: 13, color: c.mute),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
