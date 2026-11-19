import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'data/image_disk_cache.dart';
import 'models.dart';
import 'widgets.dart';

/// Profil avatarı: cihazdaki ya da buluttaki fotoğrafı yuvarlak gösterir; fotoğraf yoksa (ya da
/// yüklenemezse) baş harflerden oluşan varsayılan [Avatar]'a döner.
class ProfileAvatarView extends StatefulWidget {
  const ProfileAvatarView({
    super.key,
    required this.name,
    this.profile,
    this.size = 36,
    this.filled = false,
    this.onTap,
  });

  /// Fotoğraf yokken baş harflerin alındığı ad.
  final String name;
  final Profile? profile;
  final double size;
  final bool filled;
  final VoidCallback? onTap;

  @override
  State<ProfileAvatarView> createState() => _ProfileAvatarViewState();
}

class _ProfileAvatarViewState extends State<ProfileAvatarView> {
  Future<Uint8List?>? _local;
  String? _localPath;

  @override
  void initState() {
    super.initState();
    _syncLocal();
  }

  @override
  void didUpdateWidget(ProfileAvatarView old) {
    super.didUpdateWidget(old);
    _syncLocal();
  }

  void _syncLocal() {
    final path = widget.profile?.localAvatarPath;
    if (path == _localPath) return;
    _localPath = path;
    _local = path == null ? null : appState.readLocalImage(path);
  }

  Widget _initials() => Avatar(widget.name, size: widget.size, filled: widget.filled);

  Widget _photo(Widget image) => ClipOval(child: SizedBox(width: widget.size, height: widget.size, child: image));

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    Widget child;
    if (p != null && p.localAvatarPath != null) {
      child = FutureBuilder<Uint8List?>(
        future: _local,
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null) return _initials();
          return _photo(Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true));
        },
      );
    } else if (p != null && p.serverId != null && p.avatarVersion > 0) {
      child = _photo(
        CachedNetImage(
          url: appState.api.avatarUrl(p.serverId!, p.avatarVersion),
          headers: appState.api.authHeaders,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          loading: _initials(),
          error: (context) => _initials(),
        ),
      );
    } else {
      child = _initials();
    }
    if (widget.onTap == null) return child;
    return Semantics(
      button: true,
      label: 'Profil ve ayarlar',
      child: GestureDetector(onTap: widget.onTap, child: child),
    );
  }
}
