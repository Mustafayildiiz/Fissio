import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'email_setup_wizard.dart';

/// Ayarlar satırındaki küçük "Yeni" rozeti.
class NewBadge extends StatelessWidget {
  const NewBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(kRadiusPill)),
      child: Text('Yeni', style: FissioText.body(c, size: 12, weight: FontWeight.w700, color: c.onAccent).copyWith(height: 1)),
    );
  }
}

/// Ayarlar'daki "E-Posta ile Otomatik Fiş Aktarımı" satırı (bağımsız ikinci rehber girişi) + "Yeni" rozeti. Rozet sihirbaz ya da kart
/// bir kez açılınca kaybolur. Kendi `ListenableBuilder`'ını taşır ve [app] ile test edilebilir.
class EmailImportSettingsRow extends StatelessWidget {
  const EmailImportSettingsRow({super.key, this.app});

  /// Verilmezse global [appState].
  final AppState? app;

  @override
  Widget build(BuildContext context) {
    final a = app ?? appState;
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) => ListRow(
        key: const ValueKey('settings-email-import'),
        leading: IconTile(LucideIcons.mail, size: 30, radius: 8),
        title: 'E-Posta ile Otomatik Fiş Aktarımı',
        chevron: true,
        vertical: 10,
        trailing: a.emailImportIsNew ? const NewBadge(key: ValueKey('settings-email-new')) : null,
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmailSetupWizardPage(app: app))),
      ),
    );
  }
}

/// Ana sayfada, mevcut/güncelleme alan kullanıcıların özelliği fark etmesi için kapatılabilir bilgi kartı:
/// "Yeni: E-Faturalarını Otomatik Aktar". Yalnızca bulut senkronu açık ve sunucuda e-posta aktarımı yapılandırılmışsa görünür;
/// kapatma kalıcıdır (hesap başına). Kendi `ListenableBuilder`'ını taşır: `home_page.dart` onu `const` verir ve `const` bir çocuk
/// üst `ListenableBuilder` yeniden çizdiğinde yenilenmez (BudgetsSection ile aynı tuzak).
class EmailImportCard extends StatelessWidget {
  const EmailImportCard({super.key, this.app});

  /// Verilmezse global [appState].
  final AppState? app;

  @override
  Widget build(BuildContext context) {
    final a = app ?? appState;
    return ListenableBuilder(listenable: a, builder: (context, _) => _content(context, a));
  }

  Widget _content(BuildContext context, AppState a) {
    if (!a.showEmailImportCard) return const SizedBox.shrink();
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Material(
        key: const ValueKey('email-card'),
        color: c.surf,
        borderRadius: BorderRadius.circular(kRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmailSetupWizardPage(app: app))),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(12)),
                  child: Icon(LucideIcons.mail, size: 20, color: c.onAccent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Yeni: E-Faturalarını Otomatik Aktar', style: FissioText.body(c, size: 16, weight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        'E-fatura ve sipariş özeti mailleri fişlerine kendiliğinden eklensin.',
                        style: FissioText.body(c, size: 14, color: c.mute).copyWith(height: 1.3),
                      ),
                      const SizedBox(height: 6),
                      Text('Kur', key: const ValueKey('email-card-open'), style: FissioText.body(c, size: 14, weight: FontWeight.w700, color: c.accentInk)),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('email-card-dismiss'),
                  tooltip: 'Kapat',
                  onPressed: a.dismissEmailImportCard,
                  icon: Icon(LucideIcons.x, size: 18, color: c.mute),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
