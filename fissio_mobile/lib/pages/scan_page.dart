import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../app_state.dart';
import '../models.dart';
import '../ocr/picked_image.dart';
import '../ocr/scan_session.dart';
import '../theme.dart';
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
  late String _selectedEngine;
  late final ScanSession _session;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _selectedEngine = appState.ocrFactory.defaultEngine;
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
        engine: _selectedEngine,
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
    final manual = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Fiş Okunamadı',
          style: TextStyle(color: Colors.white, fontSize: 20),
        ),
        content: const Text(
          'Fiş net okunamadı, bilgileri manuel girmek ister misiniz? '
          'Fotoğraflar fişe eklenmeye devam eder.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Tekrar Dene',
              style: TextStyle(color: AppColors.secondaryText),
            ),
          ),
          PrimaryButton(
            label: 'Manuel Gir',
            compact: true,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (manual == true && mounted) {
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
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sayfalar (${_session.length}/${ScanSession.maxPages})',
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Sırayı değiştirmek için basılı tutup sürükleyin. Uzun fişte sayfalar yukarıdan aşağıya sıralanmalı.',
                  style: TextStyle(
                    color: AppColors.secondaryText,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                if (_session.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'Henüz sayfa yok.',
                        style: TextStyle(color: Colors.white70),
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
                        title: Text(
                          'Sayfa ${i + 1}',
                          style: const TextStyle(color: Colors.white),
                        ),
                        trailing: IconButton(
                          tooltip: 'Sayfayı sil',
                          icon: const Icon(
                            Icons.close,
                            color: AppColors.danger,
                          ),
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
    final engines = appState.ocrFactory.availableEngines;
    final pages = _session.pages;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            BackTitle(
              'Fiş Oluştur',
              trailing: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedEngine,
                    dropdownColor: AppColors.card,
                    isDense: true,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontFamily: fontFamily,
                    ),
                    items: [
                      for (final eng in engines)
                        DropdownMenuItem(
                          value: eng,
                          child: Text(
                            eng == 'paddleocr'
                                ? 'PP-OCRv4 Mobile'
                                : 'Custom OCR',
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() {
                          _selectedEngine = v;
                          appState.ocrFactory.defaultEngine = v;
                        });
                      }
                    },
                  ),
                ),
              ),
            ),
            ModeSwitch(
              scanActive: true,
              onChange: (scan) {
                if (!scan) _openManual();
              },
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: _busy
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: AppColors.accent),
                            SizedBox(height: 16),
                            Text(
                              'Fiş taranıyor ve ayrıştırılıyor...',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      )
                    : pages.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.document_scanner_outlined,
                              size: 90,
                              color: AppColors.secondaryText,
                            ),
                            SizedBox(height: 14),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 32),
                              child: Text(
                                'Fişin fotoğrafını çekin. Fiş uzunsa birden fazla fotoğraf ekleyebilirsiniz.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            SizedBox(height: 8),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 32),
                              child: Text(
                                'Fiş fotoğrafları hesabınıza kaydedilir; fişi silince silinir.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.secondaryText,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(pages.last, fit: BoxFit.contain),
                          Positioned(
                            top: 10,
                            left: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                'Sayfa ${pages.length}/${ScanSession.maxPages}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 12,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: PrimaryButton(
                                label: pages.length == 1
                                    ? 'Fişi Tara'
                                    : 'Tara (${pages.length} sayfa)',
                                compact: true,
                                onPressed: _scan,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: 'Galeriden seç (birden fazla)',
                    onPressed: _busy ? null : _addFromGallery,
                    icon: const Icon(
                      Icons.photo_library_outlined,
                      size: 32,
                      color: AppColors.secondaryText,
                    ),
                  ),
                  InkWell(
                    onTap: _busy ? null : _addFromCamera,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(
                        color: AppColors.light,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  // Deklanşörün sağı: çekilen sayfalar (önizleme + sayı); dokununca sayfa listesi.
                  InkWell(
                    onTap: _busy ? null : _openPagesSheet,
                    borderRadius: BorderRadius.circular(10),
                    child: Badge(
                      label: Text('${pages.length}'),
                      isLabelVisible: pages.isNotEmpty,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.secondaryText),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: pages.isEmpty
                            ? const Icon(
                                Icons.collections_outlined,
                                color: AppColors.secondaryText,
                              )
                            : Image.memory(pages.last, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
