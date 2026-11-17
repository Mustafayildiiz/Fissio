import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ocr/picked_image.dart';
import '../widgets.dart';

/// Bir fişe en fazla bu kadar fotoğraf bağlanabilir (sunucu sınırıyla aynı).
const int kMaxReceiptPhotos = 10;

/// "Kamera / Galeriden seç (birden fazla)" seçimini gösterir ve seçilen fotoğrafların baytlarını döner.
/// [room] eklenebilecek en fazla fotoğraf sayısıdır. Seçici cache kopyası okunup silinir; galerideki
/// orijinal dosyaya dokunulmaz (bkz. `readAndDelete`). İptalde boş liste döner.
Future<List<Uint8List>> pickReceiptPhotos(
  BuildContext context, {
  required int room,
}) async {
  if (room <= 0) {
    showMessage(
      context,
      'Bir fişe en fazla $kMaxReceiptPhotos fotoğraf eklenebilir.',
    );
    return [];
  }
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: GroupedCard(
          children: [
            ListRow(
              leading: const IconTile(LucideIcons.camera, size: 30, radius: 8),
              title: 'Kamera',
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListRow(
              leading: const IconTile(LucideIcons.images, size: 30, radius: 8),
              title: 'Galeriden seç (birden fazla)',
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    ),
  );
  if (source == null || !context.mounted) return [];
  try {
    final picker = ImagePicker();
    final List<XFile> picked;
    if (source == ImageSource.gallery && room >= 2) {
      picked = await picker.pickMultiImage(
        maxWidth: 1800,
        imageQuality: 85,
        limit: room,
      );
    } else {
      final one = await picker.pickImage(
        source: source,
        maxWidth: 1800,
        imageQuality: 85,
      );
      picked = one == null ? [] : [one];
    }
    final out = <Uint8List>[];
    for (final x in picked.take(room)) {
      out.add(await readAndDelete(x.path));
    }
    return out;
  } on PlatformException {
    if (context.mounted) {
      showMessage(
        context,
        'Kamera erişimi reddedildi. Ayarlardan izin verin veya galeriden seçin.',
      );
    }
    return [];
  }
}
