import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../dialogs.dart';
import '../theme.dart';
import '../widgets.dart';
import 'auth_page.dart';

/// Aktif oturumlar: hesabın açık olduğu cihazlar (cihaz adı, platform, son aktiflik). Tek bir cihazdan
/// oturumu uzaktan kapatabilir ya da "Tüm cihazlardan çıkış yap" ile tüm refresh token'ları geçersiz kılabilirsin.
class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key, this.loader, this.onRevoke, this.onLogoutAll});

  /// Testlerde sahte verilir.
  final Future<List<DeviceSession>> Function()? loader;
  final Future<void> Function(String id)? onRevoke;
  final Future<void> Function()? onLogoutAll;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  List<DeviceSession>? _sessions;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // _revoke'tan await sonrası da çağrılır: sayfa o arada kapandıysa dispose edilmiş State'e setState yapılmaz.
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final list = await (widget.loader ?? appState.api.sessions)();
      if (mounted) setState(() => _sessions = list);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _revoke(DeviceSession s) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Oturumu kapat',
      message: '"${s.deviceName.isEmpty ? 'Bu cihaz' : s.deviceName}" cihazındaki oturum kapatılacak.',
      confirmLabel: 'Kapat',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await (widget.onRevoke ?? appState.api.revokeSession)(s.id);
      if (s.current) {
        // Kendi oturumunu kapattıysa yerelde de çıkış yap.
        await appState.logout();
        _toAuth();
        return;
      }
      await _load();
    } on ApiException catch (e) {
      if (mounted) showError(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logoutAll() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Tüm cihazlardan çıkış yap',
      message: 'Hesabın açık olduğu tüm cihazlardaki oturumlar kapatılır; bu cihazda da yeniden giriş yapman gerekir.',
      confirmLabel: 'Çıkış yap',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await (widget.onLogoutAll ?? appState.logoutEverywhere)();
      _toAuth();
    } on ApiException catch (e) {
      if (mounted) showError(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toAuth() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthPage()),
      (_) => false,
    );
  }

  IconData _icon(String platform) => switch (platform) {
    'android' => LucideIcons.smartphone,
    'ios' => LucideIcons.smartphone,
    'web' => LucideIcons.globe,
    _ => LucideIcons.monitor,
  };

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 2) return 'Şimdi aktif';
    if (d.inHours < 1) return '${d.inMinutes} dk önce';
    if (d.inDays < 1) return '${d.inHours} sa önce';
    return '${d.inDays} gün önce';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final list = _sessions;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const NavBackBar(label: 'Ayarlar'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text('Aktif oturumlar', style: FissioText.title(c)),
            ),
            const Rule2(margin: EdgeInsets.fromLTRB(20, 16, 20, 16)),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  children: [
                    if (_error != null) ErrorBanner(_error!, onRetry: _load),
                    if (list == null && _error == null)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (list != null)
                      GroupedCard(
                        children: [
                          for (final s in list)
                            ListRow(
                              key: ValueKey(s.id),
                              leading: IconTile(_icon(s.platform), size: 36, radius: 10),
                              title: s.deviceName.isEmpty ? 'Bilinmeyen cihaz' : s.deviceName,
                              subtitle: '${s.current ? 'Bu cihaz · ' : ''}${_ago(s.lastActiveAt)}',
                              trailing: _busy
                                  ? null
                                  : TextButton(
                                      onPressed: () => _revoke(s),
                                      child: Text('Kapat', style: TextStyle(color: c.danger)),
                                    ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    if (list != null)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _logoutAll,
                        icon: Icon(LucideIcons.logOut, size: 18, color: c.danger),
                        label: Text('Tüm cihazlardan çıkış yap', style: TextStyle(color: c.danger)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: BorderSide(color: c.line, width: 1.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
