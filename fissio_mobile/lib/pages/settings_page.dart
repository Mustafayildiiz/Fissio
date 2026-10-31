import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'auth_page.dart';
import 'info_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  void _open(BuildContext context, String title, String body) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => InfoPage(title: title, body: body)),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Çıkış yap'),
        content: const Text('Oturumu kapatmak istiyor musunuz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Çıkış yap'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await appState.logout();
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthPage()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String, VoidCallback)>[
      (Icons.settings_outlined, 'Ayarlar', () => _open(context, 'Ayarlar', InfoTexts.settings)),
      (Icons.storage_outlined, 'Veri', () => _open(context, 'Veri', InfoTexts.data)),
      (Icons.support_agent, 'Destek', () => _open(context, 'Destek', InfoTexts.support)),
      (Icons.info_outline, 'Hakkımızda', () => _open(context, 'Hakkımızda', InfoTexts.about)),
      (Icons.privacy_tip_outlined, 'Gizlilik Politikası', () => _open(context, 'Gizlilik Politikası', InfoTexts.privacy)),
      (Icons.description_outlined, 'Kullanım şartları', () => _open(context, 'Kullanım şartları', InfoTexts.terms)),
      (Icons.logout, 'Çıkış yap', () => _logout(context)),
    ];
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) => Column(
        children: [
          const FissioHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.light,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        radius: 34,
                        backgroundColor: Color(0xFFE2E8F0),
                        child: Icon(Icons.person, size: 36, color: AppColors.darkText),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Aktif profil',
                              style: TextStyle(color: AppColors.darkText, fontSize: 12),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              appState.email ?? '-',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppColors.darkText, fontSize: 18),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                const Text('Ayarlar', style: TextStyle(color: Colors.white, fontSize: 16)),
                const SizedBox(height: 8),
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: AppColors.light,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: it.$3,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          child: Row(
                            children: [
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: AppColors.accent.withValues(alpha: .15),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(it.$1, size: 18, color: AppColors.accent),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  it.$2,
                                  style: const TextStyle(color: AppColors.darkText, fontSize: 15),
                                ),
                              ),
                              const Icon(Icons.chevron_right, color: AppColors.darkText),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

