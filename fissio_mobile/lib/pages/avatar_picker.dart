import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../models.dart';
import '../ocr/picked_image.dart';
import '../widgets.dart';

/// Profil fotoğrafı için istemci tarafı sınır: en çok 512x512, JPEG kalite 80 (≈50-100 KB).
const int kAvatarMaxSide = 512;
const int kAvatarQuality = 80;

/// Kaynaktan tek fotoğraf seçip küçültülmüş baytlarını döner; iptalde null. Testlerde değiştirilebilir.
Future<Uint8List?> Function(ImageSource source) avatarSourcePicker = (source) async {
  final x = await ImagePicker().pickImage(
    source: source,
    maxWidth: kAvatarMaxSide.toDouble(),
    maxHeight: kAvatarMaxSide.toDouble(),
    imageQuality: kAvatarQuality,
  );
  return x == null ? null : readAndDelete(x.path);
};

/// "Kamera / Galeri / Fotoğrafı kaldır" seçimini gösterir, sonucu [AppState]'e uygular.
Future<void> changeProfileAvatar(BuildContext context, Profile profile) async {
  final choice = await showModalBottomSheet<_AvatarChoice>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: GroupedCard(
          children: [
            ListRow(
              key: const ValueKey('avatar-camera'),
              leading: const IconTile(LucideIcons.camera, size: 30, radius: 8),
              title: 'Kamera',
              onTap: () => Navigator.pop(ctx, _AvatarChoice.camera),
            ),
            ListRow(
              key: const ValueKey('avatar-gallery'),
              leading: const IconTile(LucideIcons.images, size: 30, radius: 8),
              title: 'Galeriden seç',
              onTap: () => Navigator.pop(ctx, _AvatarChoice.gallery),
            ),
            if (profile.hasAvatar)
              ListRow(
                key: const ValueKey('avatar-remove'),
                leading: const IconTile(LucideIcons.trash2, size: 30, radius: 8),
                title: 'Fotoğrafı kaldır',
                onTap: () => Navigator.pop(ctx, _AvatarChoice.remove),
              ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  try {
    if (choice == _AvatarChoice.remove) {
      await appState.removeProfileAvatar(profile.id);
      return;
    }
    final bytes = await avatarSourcePicker(
      choice == _AvatarChoice.camera ? ImageSource.camera : ImageSource.gallery,
    );
    if (bytes == null || bytes.isEmpty) return;
    await appState.setProfileAvatar(profile.id, bytes);
  } on PlatformException {
    if (context.mounted) {
      showMessage(context, 'Kamera erişimi reddedildi. Ayarlardan izin verin veya galeriden seçin.');
    }
  } on ApiException catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
}

enum _AvatarChoice { camera, gallery, remove }
