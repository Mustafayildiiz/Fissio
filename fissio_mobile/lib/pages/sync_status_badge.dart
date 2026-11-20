import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../theme.dart';

/// Başlıkta profil avatarının soluna konan minimal bağlantı/senkron durumu rozeti (eski büyük çevrimdışı bandının yerine).
///  - Bulut senkronu KAPALI: nötr "yalnızca bu cihaz" ikonu; bağlantı olsun olmasın uyarı verilmez.
///  - Senkron AÇIK + çevrimdışı: küçük çevrimdışı ikonu; dokununca durumu açıklayan kısa bilgi.
///  - Senkron AÇIK + çevrimiçi: gizli.
class SyncStatusBadge extends StatelessWidget {
  const SyncStatusBadge({super.key, this.app});

  /// Verilmezse global [appState].
  final AppState? app;

  @override
  Widget build(BuildContext context) {
    final a = app ?? appState;
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) {
        final c = context.c;
        final local = !a.syncEnabled;
        if (!local && !a.connectionTrouble) return const SizedBox.shrink();
        final message = local ? _localMessage(a) : _offlineMessage(a);
        return Semantics(
          button: true,
          label: message,
          child: Tooltip(
            message: message,
            child: InkResponse(
              key: Key(local ? 'sync-status-badge-local' : 'sync-status-badge-offline'),
              radius: 22,
              onTap: () => _showInfo(context, local ? 'Yalnızca bu cihaz' : 'Çevrimdışısın', message),
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(
                  local ? LucideIcons.smartphone : LucideIcons.wifiOff,
                  size: 18,
                  color: local ? c.mute.withValues(alpha: .7) : c.warn,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _localMessage(AppState a) =>
      'Bulut senkronu kapalı; fişlerin yalnızca bu cihazda tutuluyor. Açmak için Ayarlar > Veri Yönetimi.';

  static String _offlineMessage(AppState a) {
    final n = a.pendingCount;
    return n > 0
        ? 'Bağlantı yok; cihazdaki son veriler gösteriliyor. $n değişiklik bağlantı gelince buluta yüklenecek.'
        : 'Bağlantı yok; cihazdaki son veriler gösteriliyor. Bağlantı gelince otomatik senkronlanır.';
  }

  static void _showInfo(BuildContext context, String title, String message) {
    final c = context.c;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, key: const Key('sync-status-title'), style: FissioText.title(c, size: 22)),
              const SizedBox(height: 8),
              Text(message, style: FissioText.body(c, size: 15, color: c.mute)),
            ],
          ),
        ),
      ),
    );
  }
}
