import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../dialogs.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'photo_picker.dart';

/// Fiş detayında fotoğraf şeridi: küçük önizlemeler (JWT başlıklı, hesaba bağlı) + "Fotoğraf ekle".
class ReceiptImageStrip extends StatelessWidget {
  const ReceiptImageStrip({super.key, required this.expense});
  final Expense expense;

  Future<void> _add(BuildContext context) async {
    final room = kMaxReceiptPhotos - expense.imageCount;
    final bytes = await pickReceiptPhotos(context, room: room);
    if (bytes.isEmpty || !context.mounted) return;
    try {
      // Sunucudaki fişe yüklenir; cihazdaki (yüklenmemiş) fişe cihaza yazılır.
      await appState.addImages(expense, bytes);
      for (final b in bytes) {
        b.fillRange(0, b.length, 0);
      }
    } on ApiException catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ids = expense.imageIds;
    final locals = expense.localImages;
    final total = ids.length + locals.length;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surf,
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  total == 0
                      ? 'Fiş fotoğrafları'
                      : 'Fiş fotoğrafları ($total)',
                  style: FissioText.body(c, weight: FontWeight.w600),
                ),
              ),
              if (total < kMaxReceiptPhotos)
                TextButton.icon(
                  onPressed: () => _add(context),
                  icon: const Icon(LucideIcons.imagePlus, size: 18),
                  label: const Text('Fotoğraf ekle'),
                ),
            ],
          ),
          if (total == 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Bu fişe henüz fotoğraf eklenmemiş.',
                style: FissioText.body(c, size: 13, color: c.mute),
              ),
            )
          else
            SizedBox(
              height: 110,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: total,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => InkWell(
                  borderRadius: BorderRadius.circular(kRadiusSm),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ReceiptImageViewer(
                        expenseId: expense.id,
                        imageIds: ids,
                        localImages: locals,
                        initialIndex: i,
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(kRadiusSm),
                    child: i < ids.length
                        ? _NetImage(
                            expenseId: expense.id,
                            imageId: ids[i],
                            width: 82,
                            height: 110,
                            fit: BoxFit.cover,
                          )
                        : _LocalImage(
                            path: locals[i - ids.length],
                            width: 82,
                            height: 110,
                            fit: BoxFit.cover,
                          ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NetImage extends StatelessWidget {
  const _NetImage({
    required this.expenseId,
    required this.imageId,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
  });
  final int expenseId;
  final int imageId;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      appState.api.imageUrl(expenseId, imageId),
      headers: appState.api.authHeaders,
      width: width,
      height: height,
      fit: fit,
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : SizedBox(
              width: width,
              height: height,
              child: const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
      errorBuilder: (context, error, stack) => Container(
        width: width,
        height: height,
        color: context.c.surf2,
        child: Icon(LucideIcons.imageOff, color: context.c.mute),
      ),
    );
  }
}

/// Cihazdaki (henüz buluta yüklenmemiş) fotoğraf.
class _LocalImage extends StatelessWidget {
  const _LocalImage({required this.path, this.width, this.height, this.fit = BoxFit.contain});
  final String path;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: appState.readLocalImage(path),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) {
          return Container(
            width: width,
            height: height,
            color: context.c.surf2,
            child: snap.connectionState == ConnectionState.done
                ? Icon(LucideIcons.imageOff, color: context.c.mute)
                : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return Image.memory(bytes, width: width, height: height, fit: fit, gaplessPlayback: true);
      },
    );
  }
}

/// Tam ekran görüntüleyici: kaydır (PageView), yakınlaştır (InteractiveViewer), sil.
class ReceiptImageViewer extends StatefulWidget {
  const ReceiptImageViewer({
    super.key,
    required this.expenseId,
    required this.imageIds,
    this.localImages = const [],
    this.initialIndex = 0,
  });
  final int expenseId;
  final List<int> imageIds;
  final List<String> localImages;
  final int initialIndex;

  @override
  State<ReceiptImageViewer> createState() => _ReceiptImageViewerState();
}

class _ReceiptImageViewerState extends State<ReceiptImageViewer> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _count => widget.imageIds.length + widget.localImages.length;

  Future<void> _delete() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Fotoğrafı sil',
      message: 'Bu fotoğraf fişten kalıcı olarak silinecek.',
      confirmLabel: 'Sil',
      destructive: true,
    );
    if (!ok) return;
    try {
      if (_index < widget.imageIds.length) {
        await appState.removeCloudImage(widget.expenseId, widget.imageIds[_index]);
      } else {
        await appState.removeLocalImage(
          widget.expenseId,
          widget.localImages[_index - widget.imageIds.length],
        );
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / $_count'),
        actions: [
          IconButton(
            tooltip: 'Fotoğrafı sil',
            icon: Icon(LucideIcons.trash2, color: context.c.danger),
            onPressed: _delete,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: _count,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Center(
            child: i < widget.imageIds.length
                ? _NetImage(
                    expenseId: widget.expenseId,
                    imageId: widget.imageIds[i],
                  )
                : _LocalImage(path: widget.localImages[i - widget.imageIds.length]),
          ),
        ),
      ),
    );
  }
}
