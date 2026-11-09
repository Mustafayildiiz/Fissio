import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'shell_page.dart';

/// Görseldeki "Profil Seç" ekranı: 2 sütunlu yuvarlak profil daireleri
/// ve mor kesikli çizgili "+ Yeni Profil" dairesi.
class ProfileSelectPage extends StatefulWidget {
  const ProfileSelectPage({super.key});

  @override
  State<ProfileSelectPage> createState() => _ProfileSelectPageState();
}

class _ProfileSelectPageState extends State<ProfileSelectPage> {
  String? _busyId;

  @override
  void initState() {
    super.initState();
    if (appState.profiles.isEmpty) {
      appState.loadProfiles();
    }
  }

  Future<void> _select(UserProfile p) async {
    if (_busyId != null) return;
    setState(() => _busyId = p.id);
    try {
      await appState.selectProfile(p);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ShellPage()),
        (_) => false,
      );
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _addProfileDialog() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Yeni Profil',
          style: TextStyle(color: Colors.white, fontSize: 20),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.darkText),
          decoration: lightField('Profil adı', hint: 'Örn: Ev, İş, Kişisel'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Vazgeç',
              style: TextStyle(color: AppColors.secondaryText),
            ),
          ),
          PrimaryButton(
            label: 'Oluştur',
            compact: true,
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => _busyId = '__new__');
    try {
      await appState.createProfile(name);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ShellPage()),
        (_) => false,
      );
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _renameDialog(UserProfile p) async {
    final ctrl = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Profili Yeniden Adlandır',
          style: TextStyle(color: Colors.white, fontSize: 20),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.darkText),
          decoration: lightField('Profil adı', hint: 'Örn: Ev, İş, Kişisel'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Vazgeç',
              style: TextStyle(color: AppColors.secondaryText),
            ),
          ),
          PrimaryButton(
            label: 'Kaydet',
            compact: true,
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await appState.renameProfile(p.id, name);
    }
  }

  Future<void> _deleteProfile(UserProfile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Profili Sil',
          style: TextStyle(color: Colors.white, fontSize: 20),
        ),
        content: Text(
          '"${p.name}" profilini silmek istediğinize emin misiniz?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Vazgeç',
              style: TextStyle(color: AppColors.secondaryText),
            ),
          ),
          PrimaryButton(
            label: 'Sil',
            compact: true,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok == true) {
      await appState.deleteProfile(p.id);
    }
  }

  void _showProfileOptions(UserProfile p) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                p.name,
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.edit, color: AppColors.secondaryText),
                title: const Text('İsmi Düzenle',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _renameDialog(p);
                },
              ),
              if (appState.profiles.length > 1)
                ListTile(
                  leading:
                      const Icon(Icons.delete_outline, color: AppColors.danger),
                  title: const Text('Profili Sil',
                      style: TextStyle(color: AppColors.danger)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _deleteProfile(p);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            final items = appState.profiles;
            return Column(
              children: [
                const FissioHeader(),
                const SizedBox(height: 36),
                const Text(
                  'Profil Seç',
                  style: TextStyle(color: Colors.white, fontSize: 28),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Düzenlemek veya silmek için basılı tutun',
                  style: TextStyle(color: AppColors.secondaryText, fontSize: 13),
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: GridView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 8,
                        ),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 24,
                          crossAxisSpacing: 24,
                          childAspectRatio: 1,
                        ),
                        itemCount: items.length + 1,
                        itemBuilder: (context, i) {
                          if (i < items.length) {
                            final p = items[i];
                            final active = p.id == appState.activeProfileId;
                            final busy = _busyId == p.id;
                            return _ProfileCircle(
                              label: p.name,
                              active: active,
                              busy: busy,
                              onTap: () => _select(p),
                              onLongPress: () => _showProfileOptions(p),
                            );
                          }
                          return _NewProfileCircle(
                            busy: _busyId == '__new__',
                            onTap: _addProfileDialog,
                          );
                        },
                      ),
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

class _ProfileCircle extends StatelessWidget {
  const _ProfileCircle({
    required this.label,
    required this.active,
    required this.busy,
    required this.onTap,
    required this.onLongPress,
  });

  final String label;
  final bool active;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: busy ? null : onTap,
      onLongPress: busy ? null : onLongPress,
      customBorder: const CircleBorder(),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.card,
          border: Border.all(
            color: active
                ? AppColors.accent
                : AppColors.secondaryText.withValues(alpha: .35),
            width: active ? 2.2 : 1.4,
          ),
        ),
        padding: const EdgeInsets.all(14),
        child: Center(
          child: busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
        ),
      ),
    );
  }
}

class _NewProfileCircle extends StatelessWidget {
  const _NewProfileCircle({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: busy ? null : onTap,
      customBorder: const CircleBorder(),
      child: CustomPaint(
        painter: _DashedCirclePainter(color: AppColors.accent),
        child: Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.card,
          ),
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.add,
                        size: 28,
                        color: Color(0xFF64748B),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Yeni',
                        style: TextStyle(color: Colors.white, fontSize: 18),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Profil',
                        style: TextStyle(
                          color: AppColors.secondaryText,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _DashedCirclePainter extends CustomPainter {
  _DashedCirclePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final radius = (math.min(size.width, size.height) / 2) - 1;
    final center = Offset(size.width / 2, size.height / 2);
    const segments = 36;
    const step = (2 * math.pi) / segments;
    for (var i = 0; i < segments; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        i * step,
        step * 0.55,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) =>
      oldDelegate.color != color;
}
