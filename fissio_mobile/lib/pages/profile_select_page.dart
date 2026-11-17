import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../dialogs.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'shell_page.dart';

/// "Profil seçin": 2'li kare kartlar ve kesikli çerçeveli "Yeni profil" kartı.
/// Düzenlemek/silmek için karta uzun basılır ya da "Profilleri yönet" açılır.
class ProfileSelectPage extends StatefulWidget {
  const ProfileSelectPage({super.key});

  @override
  State<ProfileSelectPage> createState() => _ProfileSelectPageState();
}

class _ProfileSelectPageState extends State<ProfileSelectPage> {
  String? _busyId;
  bool _manage = false;

  void _openShell() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ShellPage()),
      (_) => false,
    );
  }

  Future<void> _select(Profile p) async {
    if (_busyId != null) return;
    setState(() => _busyId = p.id);
    try {
      await appState.selectProfile(p);
      if (!mounted) return;
      _openShell();
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _addProfileDialog() async {
    final name = await showTextPrompt(
      context,
      title: 'Yeni profil',
      hint: 'Örn: Ev, İş, Kişisel',
      confirmLabel: 'Oluştur',
    );
    if (name == null || name.isEmpty) return;
    setState(() => _busyId = '__new__');
    try {
      await appState.createProfile(name);
      if (!mounted) return;
      _openShell();
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _renameDialog(Profile p) async {
    final name = await showTextPrompt(
      context,
      title: 'Profili yeniden adlandır',
      hint: 'Örn: Ev, İş, Kişisel',
      initial: p.name,
      confirmLabel: 'Kaydet',
    );
    if (name != null && name.isNotEmpty) {
      try {
        await appState.renameProfile(p.id, name);
      } on ApiException catch (e) {
        if (mounted) showMessage(context, e.message);
      }
    }
  }

  Future<void> _deleteProfile(Profile p) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Profili sil',
      message: '"${p.name}" profilini silmek istediğinize emin misiniz?',
      confirmLabel: 'Sil',
      destructive: true,
    );
    if (!ok) return;
    try {
      await appState.deleteProfile(p.id);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  void _showProfileOptions(Profile p) {
    final c = context.c;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(p.name, style: FissioText.title(c, size: 22)),
              const SizedBox(height: 12),
              GroupedCard(
                children: [
                  ListRow(
                    leading: IconTile(LucideIcons.pencil, size: 30, radius: 8),
                    title: 'İsmi düzenle',
                    onTap: () {
                      Navigator.pop(ctx);
                      _renameDialog(p);
                    },
                  ),
                  if (appState.profiles.length > 1)
                    ListRow(
                      leading: IconTile(LucideIcons.trash2, size: 30, radius: 8),
                      title: 'Profili sil',
                      titleColor: c.danger,
                      onTap: () {
                        Navigator.pop(ctx);
                        _deleteProfile(p);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            final items = appState.profiles;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('FISSIO', style: FissioText.label(c)),
                      const SizedBox(height: 6),
                      Text('Profil seçin', style: FissioText.title(c)),
                      if (appState.email != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          appState.email!,
                          style: FissioText.body(c, size: 14, color: c.mute),
                        ),
                      ],
                    ],
                  ),
                ),
                const Rule2(margin: EdgeInsets.fromLTRB(20, 20, 20, 24)),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: GridView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1,
                        ),
                        itemCount: items.length + 1,
                        itemBuilder: (context, i) {
                          if (i < items.length) {
                            final p = items[i];
                            return _ProfileCard(
                              profile: p,
                              active: p.id == appState.activeProfileId,
                              busy: _busyId == p.id,
                              manage: _manage,
                              onTap: () => _select(p),
                              onOptions: () => _showProfileOptions(p),
                            );
                          }
                          return _NewProfileCard(
                            busy: _busyId == '__new__',
                            onTap: _addProfileDialog,
                          );
                        },
                      ),
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _manage = !_manage),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _manage ? 'Bitti' : 'Profilleri yönet',
                            style: FissioText.body(
                              c,
                              size: 15,
                              weight: FontWeight.w600,
                              color: _manage ? c.accentInk : c.mute,
                            ),
                          ),
                        ),
                        if (!_manage)
                          Icon(LucideIcons.chevronRight, size: 18, color: c.mute),
                      ],
                    ),
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

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.active,
    required this.busy,
    required this.manage,
    required this.onTap,
    required this.onOptions,
  });

  final Profile profile;
  final bool active;
  final bool busy;
  final bool manage;
  final VoidCallback onTap;
  final VoidCallback onOptions;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.surf,
      borderRadius: BorderRadius.circular(kRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : (manage ? onOptions : onTap),
        onLongPress: busy ? null : onOptions,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  busy
                      ? SizedBox(
                          width: 52,
                          height: 52,
                          child: Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: c.accentInk,
                              ),
                            ),
                          ),
                        )
                      : Avatar(profile.name, size: 52, filled: active),
                  const Spacer(),
                  if (manage)
                    Icon(LucideIcons.ellipsis, size: 22, color: c.mute),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: FissioText.body(c, size: 17, weight: FontWeight.w600),
                  ),
                  if (profile.state != SyncState.synced)
                    Text(
                      profile.state == SyncState.pending
                          ? 'Yüklenmeyi bekliyor'
                          : 'Yalnızca bu cihazda',
                      style: FissioText.body(c, size: 13, color: c.mute),
                    )
                  else if (active)
                    Text(
                      'Son kullanılan',
                      style: FissioText.body(c, size: 13, color: c.mute),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewProfileCard extends StatelessWidget {
  const _NewProfileCard({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(kRadius),
      child: DashedBox(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: c.accentInk, width: 2),
                ),
                child: busy
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2, color: c.accentInk),
                      )
                    : Icon(LucideIcons.plus, size: 24, color: c.accentInk),
              ),
              Text(
                'Yeni profil',
                style: FissioText.body(c, size: 17, weight: FontWeight.w600, color: c.accentInk),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
