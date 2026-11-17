import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../dialogs.dart';
import '../models.dart';
import '../ocr/ocr_engine.dart';
import '../ocr/picked_image.dart';
import '../ocr/scan_session.dart';
import '../theme.dart';
import '../theme_controller.dart';
import '../widgets.dart';
import 'receipt_form_page.dart';

/// Tara ekranı = çekim oturumu. Uzun fişler için birden çok fotoğraf (kamera veya galeriden çoklu
/// seçim) eklenir; "Tara" tüm sayfaları tek çağrıda OCR'lar ve tek fiş olarak ayrıştırır.
/// Fotoğraflar bellekte tutulur; fiş kaydedilirken hesaba (sunucuya) yüklenir.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key, this.initialPages});

  /// Fiş formundan dönüşte mevcut fotoğrafların kaybolmaması için.
  final List<Uint8List>? initialPages;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  late final ScanSession _session;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _session = ScanSession(initial: widget.initialPages);
  }

  /// Taslağın sahipliği: sayfa baytları taslağa (kayıtta yüklenmek üzere) devredilir.
  ReceiptDraft _draftWith(ReceiptDraft base) {
    base.pendingImages = List.of(_session.pages);
    return base;
  }

  Future<void> _addFromCamera() async {
    if (_busy) return;
    if (_session.isFull) {
      showMessage(
        context,
        'En fazla ${ScanSession.maxPages} sayfa eklenebilir.',
      );
      return;
    }
    await _guard(() async {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1800,
        imageQuality: 85,
      );
      if (picked == null) return; // iptal: hata gösterme
      _session.add(await readAndDelete(picked.path));
    });
  }

  Future<void> _addFromGallery() async {
    if (_busy) return;
    if (_session.isFull) {
      showMessage(
        context,
        'En fazla ${ScanSession.maxPages} sayfa eklenebilir.',
      );
      return;
    }
    await _guard(() async {
      final picker = ImagePicker();
      final List<XFile> picked;
      if (_session.remaining >= 2) {
        // Birden fazla fiş fotoğrafı seçilebilir.
        picked = await picker.pickMultiImage(
          maxWidth: 1800,
          imageQuality: 85,
          limit: _session.remaining,
        );
      } else {
        final one = await picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 1800,
          imageQuality: 85,
        );
        picked = one == null ? [] : [one];
      }
      if (picked.isEmpty) return;
      var skipped = 0;
      for (final x in picked) {
        // Cache kopyası okunup silinir; galerideki orijinale dokunulmaz.
        final bytes = await readAndDelete(x.path);
        if (!_session.add(bytes)) skipped++;
      }
      if (skipped > 0 && mounted) {
        showMessage(
          context,
          'Sayfa sınırı (${ScanSession.maxPages}) nedeniyle $skipped fotoğraf eklenmedi.',
        );
      }
    });
  }

  Future<void> _guard(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } on PlatformException {
      if (mounted) {
        showMessage(
          context,
          'Kamera erişimi reddedildi. Ayarlardan izin verin veya galeriden seçin.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    if (_busy || _session.isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await appState.scanAndParseReceipt(
        _session.pages,
        engine: themeController.ocrEngine,
      );
      if (!mounted) return;
      if (res.ocr.isEmpty || res.parsed.needsManual) {
        await _showUnreadableModal();
        return;
      }
      final draft = _draftWith(ReceiptDraft.fromParsed(res.parsed));
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ReceiptFormPage(initialDraft: draft)),
      );
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showUnreadableModal() async {
    final manual = await showConfirmDialog(
      context,
      title: 'Fiş okunamadı',
      message: 'Fiş net okunamadı, bilgileri manuel girmek ister misiniz? '
          'Fotoğraflar fişe eklenmeye devam eder.',
      confirmLabel: 'Manuel gir',
      cancelLabel: 'Tekrar dene',
    );
    if (manual && mounted) {
      _openManual();
    }
  }

  /// Manuel girişe geç; çekilen fotoğraflar taslakla birlikte taşınır (kaybolmaz).
  void _openManual() {
    final draft = _draftWith(ReceiptDraft());
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ReceiptFormPage(initialDraft: draft)),
    );
  }

  Future<void> _openPagesSheet() async {
    final c = context.c;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sayfalar (${_session.length}/${ScanSession.maxPages})',
                  style: FissioText.title(c, size: 22),
                ),
                const SizedBox(height: 6),
                Text(
                  'Sırayı değiştirmek için basılı tutup sürükleyin. Uzun fişte sayfalar yukarıdan aşağıya sıralanmalı.',
                  style: FissioText.body(c, size: 13, color: c.mute),
                ),
                const SizedBox(height: 8),
                if (_session.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'Henüz sayfa yok.',
                        style: FissioText.body(c, color: c.mute),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * .5,
                    ),
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      itemCount: _session.length,
                      onReorderItem: (o, n) {
                        _session.move(o, n);
                        setSheet(() {});
                        setState(() {});
                      },
                      itemBuilder: (_, i) => ListTile(
                        key: ValueKey(_session.pages[i]),
                        contentPadding: EdgeInsets.zero,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            _session.pages[i],
                            width: 48,
                            height: 64,
                            fit: BoxFit.cover,
                          ),
                        ),
                        title: Text('Sayfa ${i + 1}', style: FissioText.body(c)),
                        trailing: IconButton(
                          tooltip: 'Sayfayı sil',
                          icon: Icon(LucideIcons.x, color: c.danger),
                          onPressed: () {
                            _session.removeAt(i);
                            setSheet(() {});
                            setState(() {});
                          },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final pages = _session.pages;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TopBar(
              leading: BarAction('Vazgeç', onTap: () => Navigator.maybePop(context)),
              title: 'Yeni fiş',
            ),
            ModeSwitch(
              scanActive: true,
              onChange: (scan) {
                if (!scan) _openManual();
              },
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1918),
                  borderRadius: BorderRadius.circular(kRadius),
                ),
                clipBehavior: Clip.antiAlias,
                child: _busy
                    ? const _ScanBusy()
                    : pages.isEmpty
                        ? _ScanEmpty(engine: ocrEngineLabel(themeController.ocrEngine))
                        : Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.memory(pages.last, fit: BoxFit.contain),
                              Positioned(
                                top: 12,
                                left: 12,
                                child: _Pill('Sayfa ${pages.length}/${ScanSession.maxPages}'),
                              ),
                              Positioned(
                                bottom: 14,
                                left: 20,
                                right: 20,
                                child: PrimaryButton(
                                  label: pages.length == 1
                                      ? 'Fişi tara'
                                      : 'Tara (${pages.length} sayfa)',
                                  icon: LucideIcons.scanLine,
                                  onPressed: _scan,
                                ),
                              ),
                            ],
                          ),
              ),
            ),
            SizedBox(
              height: 130,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Semantics(
                      button: true,
                      label: 'Galeriden seç (birden fazla)',
                      child: GestureDetector(
                        onTap: _busy ? null : _addFromGallery,
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: c.surf2,
                            borderRadius: BorderRadius.circular(kRadiusSm),
                          ),
                          child: Icon(LucideIcons.images, size: 22, color: c.ink),
                        ),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: 'Fotoğraf çek',
                      child: GestureDetector(
                        onTap: _busy ? null : _addFromCamera,
                        child: Container(
                          width: 78,
                          height: 78,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: c.ink, width: 4),
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(shape: BoxShape.circle, color: c.accent),
                          ),
                        ),
                      ),
                    ),
                    // Deklanşörün sağı: çekilen sayfalar (önizleme + sayı); dokununca sayfa listesi.
                    GestureDetector(
                      onTap: _busy ? null : _openPagesSheet,
                      child: Badge(
                        label: Text('${pages.length}'),
                        isLabelVisible: pages.isNotEmpty,
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: c.surf2,
                            borderRadius: BorderRadius.circular(kRadiusSm),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: pages.isEmpty
                              ? Icon(LucideIcons.layers, size: 22, color: c.mute)
                              : Image.memory(pages.last, fit: BoxFit.cover),
                        ),
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

class _Pill extends StatelessWidget {
  const _Pill(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0x99000000),
          borderRadius: BorderRadius.circular(kRadiusPill),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontFamily: fontFamily,
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.white,
            height: 1,
          ),
        ),
      );
}

class _ScanBusy extends StatelessWidget {
  const _ScanBusy();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: c.accent),
          const SizedBox(height: 16),
          const Text(
            'Fiş taranıyor ve ayrıştırılıyor...',
            style: TextStyle(fontFamily: fontFamily, color: Colors.white, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// Boş vizör: accent köşe parantezleri, tarama çizgisi ve yönerge.
class _ScanEmpty extends StatelessWidget {
  const _ScanEmpty({required this.engine});
  final String engine;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget corner(Alignment a) {
      final top = a.y < 0, left = a.x < 0;
      final side = BorderSide(color: c.accent, width: 4);
      const r = Radius.circular(kRadiusSm);
      return Align(
        alignment: a,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            border: Border(
              top: top ? side : BorderSide.none,
              bottom: top ? BorderSide.none : side,
              left: left ? side : BorderSide.none,
              right: left ? BorderSide.none : side,
            ),
            borderRadius: BorderRadius.only(
              topLeft: top && left ? r : Radius.zero,
              topRight: top && !left ? r : Radius.zero,
              bottomLeft: !top && left ? r : Radius.zero,
              bottomRight: !top && !left ? r : Radius.zero,
            ),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 36,
          right: 36,
          top: 40,
          bottom: 100,
          child: Stack(
            children: [
              corner(Alignment.topLeft),
              corner(Alignment.topRight),
              corner(Alignment.bottomLeft),
              corner(Alignment.bottomRight),
              Align(
                alignment: const Alignment(0, -.08),
                child: Container(
                  height: 2,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: c.accent,
                    boxShadow: [BoxShadow(color: c.accent, blurRadius: 12)],
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _Pill('Fişi çerçeveye hizalayın'),
              const SizedBox(height: 10),
              Text(
                'Uzun fişte birden fazla fotoğraf ekleyebilirsiniz\n$engine',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: fontFamily,
                  color: Color(0xFF9B9797),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
