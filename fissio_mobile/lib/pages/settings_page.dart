import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'auth_page.dart';
import 'info_page.dart';
import 'preferences_page.dart';
import 'profile_select_page.dart';

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
      builder: (context, _) =>
          Avatar(appState.displayName, onTap: () => openSettings(context)),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  void _open(BuildContext context, String title, String body) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => InfoPage(title: title, body: body)),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
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
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appState,
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
                                Avatar(appState.displayName, size: 60, filled: true),
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
                        _row(context, LucideIcons.database, 'Veri',
                            () => _open(context, 'Veri', InfoTexts.data)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    GroupedCard(
                      children: [
                        _row(context, LucideIcons.lifeBuoy, 'Destek',
                            () => _open(context, 'Destek', InfoTexts.support)),
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
                    GroupedCard(
                      children: [
                        _row(context, LucideIcons.logIn, 'Giriş / Kayıt',
                            () => _push(context, const AuthPage())),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 18, 4, 0),
                      child: Text(
                        'Fissio · Sürüm 1.0',
                        style: FissioText.body(c, size: 13, color: c.mute),
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
