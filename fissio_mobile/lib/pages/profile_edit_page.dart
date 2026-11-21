import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../dialogs.dart';
import '../models.dart';
import '../profile_avatar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'avatar_picker.dart';

/// "Profili yeniden adlandır" diyaloğu ve kaydı; hem profil seçme ekranı hem profil düzenleme ekranı kullanır
/// (tek rename arayüzü). Hata ([ApiException]) toast olarak gösterilir.
Future<void> renameProfileWithDialog(BuildContext context, Profile p, {AppState? app}) async {
  final a = app ?? appState;
  final name = await showTextPrompt(
    context,
    title: 'Profili yeniden adlandır',
    hint: 'Örn: Ev, İş, Kişisel',
    initial: p.name,
    confirmLabel: 'Kaydet',
  );
  if (name == null || name.isEmpty || name == p.name) return;
  try {
    await a.renameProfile(p.id, name);
  } on ApiException catch (e) {
    if (context.mounted) showError(context, e.message);
  }
}

/// Aktif profilin adını ve avatarını düzenler ("Profili düzenle"). Ad değişikliği sunucuya yazıldığından bulut
/// senkronu kapalıyken satır devre dışıdır ve nedeni yazılır (kayıt denemesi hata vermek yerine baştan kapalı).
class ProfileEditPage extends StatelessWidget {
  const ProfileEditPage({super.key, this.app});

  /// Testlerde enjekte edilir; varsayılan global [appState].
  final AppState? app;

  @override
  Widget build(BuildContext context) {
    final a = app ?? appState;
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: a,
          builder: (context, _) {
            final p = a.activeProfile;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const NavBackBar(label: 'Ayarlar'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text('Profili düzenle', style: FissioText.title(c)),
                ),
                Expanded(
                  child: p == null
                      ? Center(child: Text('Aktif profil yok.', style: FissioText.body(c, color: c.mute)))
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
                          children: [
                            Center(
                              child: GestureDetector(
                                key: const ValueKey('edit-avatar'),
                                onTap: () => changeProfileAvatar(context, p),
                                child: ProfileAvatarView(name: a.displayName, profile: p, size: 96, filled: true),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Center(
                              child: TextButton(
                                key: const ValueKey('edit-avatar-change'),
                                onPressed: () => changeProfileAvatar(context, p),
                                child: Text('Fotoğrafı değiştir', style: TextStyle(color: c.accentInk)),
                              ),
                            ),
                            const SizedBox(height: 14),
                            const SectionLabel('Profil adı'),
                            const SizedBox(height: 8),
                            GroupedCard(
                              children: [
                                ListRow(
                                  key: const ValueKey('edit-name'),
                                  leading: IconTile(LucideIcons.pencil, size: 30, radius: 8),
                                  title: p.name,
                                  subtitle: a.syncEnabled
                                      ? 'Adı değiştirmek için dokun'
                                      : 'Ad değiştirmek için bulut senkronu açık olmalı (Veri Yönetimi).',
                                  chevron: a.syncEnabled,
                                  onTap: a.syncEnabled ? () => renameProfileWithDialog(context, p, app: a) : null,
                                ),
                              ],
                            ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
