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
    final room = kMaxReceiptPhotos - expense.imageIds.length;
    final bytes = await pickReceiptPhotos(context, room: room);
    if (bytes.isEmpty || !context.mounted) return;
    try {
      await appState.api.uploadImages(expense.id, bytes);
      for (final b in bytes) {
        b.fillRange(0, b.length, 0);
      }
      await appState.refresh();
    } on ApiException catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ids = expense.imageIds;
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
                  ids.isEmpty
                      ? 'Fiş fotoğrafları'
                      : 'Fiş fotoğrafları (${ids.length})',
                  style: FissioText.body(c, weight: FontWeight.w600),
                ),
              ),
              if (ids.length < kMaxReceiptPhotos)
                TextButton.icon(
                  onPressed: () => _add(context),
                  icon: const Icon(LucideIcons.imagePlus, size: 18),
                  label: const Text('Fotoğraf ekle'),
                ),
            ],
          ),
          if (ids.isEmpty)
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
                itemCount: ids.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => InkWell(
                  borderRadius: BorderRadius.circular(kRadiusSm),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ReceiptImageViewer(
                        expenseId: expense.id,
                        imageIds: ids,
                        initialIndex: i,
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(kRadiusSm),
                    child: _NetImage(
                      expenseId: expense.id,
                      imageId: ids[i],
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

/// Tam ekran görüntüleyici: kaydır (PageView), yakınlaştır (InteractiveViewer), sil.
class ReceiptImageViewer extends StatefulWidget {
  const ReceiptImageViewer({
    super.key,
    required this.expenseId,
    required this.imageIds,
    this.initialIndex = 0,
  });
  final int expenseId;
  final List<int> imageIds;
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
      await appState.api.deleteImage(widget.expenseId, widget.imageIds[_index]);
      await appState.refresh();
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
        title: Text('${_index + 1} / ${widget.imageIds.length}'),
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
        itemCount: widget.imageIds.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Center(
            child: _NetImage(
              expenseId: widget.expenseId,
              imageId: widget.imageIds[i],
            ),
          ),
        ),
      ),
    );
  }
}
