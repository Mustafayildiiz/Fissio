import 'dart:async';
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
import '../services/scan_camera.dart';
import '../theme.dart';
import '../theme_controller.dart';
import '../widgets.dart';
import 'digital_import.dart';
import 'receipt_form_page.dart';

/// Galeriden en çok [remaining] fotoğraf seçer (iptal = boş liste). Testlerde değiştirilebilir.
typedef GalleryPicker = Future<List<Uint8List>> Function(int remaining);

Future<List<Uint8List>> pickFromGallery(int remaining) async {
  final picker = ImagePicker();
  final List<XFile> picked;
  if (remaining >= 2) {
    // Birden fazla fiş fotoğrafı seçilebilir.
    picked = await picker.pickMultiImage(maxWidth: 1800, imageQuality: 85, limit: remaining);
  } else {
    final one = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1800, imageQuality: 85);
    picked = one == null ? [] : [one];
  }
  // Cache kopyası okunup silinir; galerideki orijinale dokunulmaz.
  return [for (final x in picked) await readAndDelete(x.path)];
}

enum _CamState { loading, ready, paused, denied, noCamera, unavailable }

/// Tara ekranı = çekim oturumu. Uygulama içi canlı kamera ile (veya galeriden çoklu seçimle)
/// bir fişin birden çok sayfası eklenir; "Taramayı başlat" tüm sayfaları tek çağrıda OCR'lar ve
/// tek fiş olarak ayrıştırır. Fotoğraflar bellekte tutulur; fiş kaydedilirken hesaba yüklenir.
class ScanPage extends StatefulWidget {
  const ScanPage({
    super.key,
    this.initialPages,
    this.camera,
    this.pickGallery = pickFromGallery,
    this.pickPdf = pickPdfFile,
  });

  /// Fiş formundan dönüşte mevcut fotoğrafların kaybolmaması için.
  final List<Uint8List>? initialPages;

  /// Kamera donanımı bu portun arkasındadır; verilmezse genel [scanCameraPort] kullanılır.
  final ScanCameraPort? camera;
  final GalleryPicker pickGallery;

  /// "Dijital Fiş / PDF Ekle" için PDF seçici (testlerde değiştirilebilir).
  final PdfPicker pickPdf;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> with WidgetsBindingObserver {
  late final ScanSession _session;
  bool _busy = false; // çekim / galeri / OCR sürerken ikinci işlemi engeller
  bool _scanning = false; // yalnızca OCR: vizörün üstünde ilerleme gösterir

  ScanCameraPort get _port => widget.camera ?? scanCameraPort;
  ScanCameraController? _cam;
  _CamState _camState = _CamState.loading;
  int _openSeq = 0; // geç dönen open() çağrılarını geçersiz kılar
  ScanFlash _flash = ScanFlash.off;
  Offset? _focusPoint; // vizör içindeki piksel konumu (odak halkası)
  Timer? _focusTimer;
  bool _awaitingSettings = false; // kullanıcı ayarlara gönderildi: dönüşte kamerayı yeniden dene

  @override
  void initState() {
    super.initState();
    _session = ScanSession(initial: widget.initialPages);
    WidgetsBinding.instance.addObserver(this);
    _openCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _openSeq++;
    _focusTimer?.cancel();
    final cam = _cam;
    _cam = null;
    if (cam != null) unawaited(cam.dispose());
    super.dispose();
  }

  /// Arka plana alınınca kamera kaynağı bırakılır, dönüşte yeniden açılır (çekilen sayfalar korunur).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        // İlk açılışta işletim sisteminin izin penceresi de `inactive` üretir; açılış sürerken
        // kamerayı bırakmak o açılışı iptal ederdi. Yalnızca açık kamera bırakılır.
        if (_camState == _CamState.ready) _releaseCamera();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (_camState == _CamState.ready || _camState == _CamState.loading) _releaseCamera();
      case AppLifecycleState.resumed:
        if (_camState == _CamState.paused) {
          _openCamera();
        } else if (_camState == _CamState.denied && _awaitingSettings) {
          // Kullanıcı ayarlardan dönüyor; izin penceresi sonrası sıradan dönüşlerde tekrar sorulmaz.
          _awaitingSettings = false;
          _openCamera();
        }
    }
  }

  void _releaseCamera() {
    _openSeq++; // bekleyen open() sonucu atılır
    final cam = _cam;
    _cam = null;
    if (cam != null) unawaited(cam.dispose());
    if (mounted) setState(() => _camState = _CamState.paused);
  }

  Future<void> _openSettings() {
    _awaitingSettings = true;
    return _port.openSettings();
  }

  Future<void> _openCamera() async {
    final seq = ++_openSeq;
    final old = _cam;
    _cam = null;
    if (old != null) unawaited(old.dispose());
    if (mounted) setState(() => _camState = _CamState.loading);
    try {
      final cam = await _port.open();
      if (!mounted || seq != _openSeq) {
        unawaited(cam.dispose());
        return;
      }
      if (_flash != ScanFlash.off) await cam.setFlash(_flash);
      if (!mounted || seq != _openSeq) {
        unawaited(cam.dispose());
        return;
      }
      setState(() {
        _cam = cam;
        _camState = _CamState.ready;
      });
    } on ScanCameraException catch (e) {
      if (!mounted || seq != _openSeq) return;
      setState(() {
        _camState = switch (e.kind) {
          ScanCameraFailure.permissionDenied => _CamState.denied,
          ScanCameraFailure.noCamera => _CamState.noCamera,
          ScanCameraFailure.unavailable => _CamState.unavailable,
        };
      });
    } catch (_) {
      if (!mounted || seq != _openSeq) return;
      setState(() => _camState = _CamState.unavailable);
    }
  }

  /// Taslağın sahipliği: sayfa baytları taslağa (kayıtta yüklenmek üzere) devredilir.
  ReceiptDraft _draftWith(ReceiptDraft base) {
    base.pendingImages = List.of(_session.pages);
    return base;
  }

  bool _checkRoom() {
    if (!_session.isFull) return true;
    showMessage(context, 'En fazla ${ScanSession.maxPages} sayfa eklenebilir.');
    return false;
  }

  Future<void> _capture() async {
    final cam = _cam;
    if (_busy || cam == null || !_checkRoom()) return;
    setState(() => _busy = true);
    try {
      final bytes = await cam.capture();
      if (!mounted) return;
      if (!_session.add(bytes)) showMessage(context, 'Fotoğraf eklenemedi.');
    } catch (_) {
      if (mounted) showMessage(context, 'Fotoğraf çekilemedi. Tekrar deneyin.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cycleFlash() async {
    final cam = _cam;
    if (cam == null) return;
    final next = _flash.next;
    setState(() => _flash = next);
    await cam.setFlash(next);
  }

  /// [local] vizör içindeki piksel konumu (halka için), [normalized] önizleme üzerindeki 0..1 noktası.
  void _focus(Offset local, Offset normalized) {
    final cam = _cam;
    if (cam == null) return;
    cam.focusAt(normalized);
    _focusTimer?.cancel();
    setState(() => _focusPoint = local);
    _focusTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _focusPoint = null);
    });
  }

  Future<void> _addFromGallery() async {
    if (_busy || !_checkRoom()) return;
    setState(() => _busy = true);
    try {
      final picked = await widget.pickGallery(_session.remaining);
      var skipped = 0;
      for (final bytes in picked) {
        if (!_session.add(bytes)) skipped++;
      }
      if (skipped > 0 && mounted) {
        showMessage(
          context,
          'Sayfa sınırı (${ScanSession.maxPages}) nedeniyle $skipped fotoğraf eklenmedi.',
        );
      }
    } on PlatformException {
      if (mounted) showMessage(context, 'Galeriye erişilemedi. Ayarlardan izin verin.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    if (_busy || _session.isEmpty) return;
    setState(() {
      _busy = true;
      _scanning = true;
    });
    try {
      var res = await appState.scanAndParseReceipt(
        _session.pages,
        engine: themeController.ocrEngine,
      );
      if (!mounted) return;
      // Kısmi sonuç: bazı sayfalar okunamadı. Yalnız onları yeniden tara (en fazla 2 kez) ya da eksik haliyle devam et.
      for (var attempt = 0; attempt < 2 && res.ocr.failedPages.isNotEmpty; attempt++) {
        final pagesText = res.ocr.failedPages.join(', ');
        final retry = await showConfirmDialog(
          context,
          title: 'Bazı sayfalar okunamadı',
          message: '$pagesText. sayfa okunamadı. Yalnızca bu sayfaları yeniden taramak ister misiniz? '
              'Aksi halde fiş eksik sayfalarla açılır; tutarları kontrol edin.',
          confirmLabel: 'Yeniden tara',
          cancelLabel: 'Eksik haliyle devam et',
        );
        if (!retry || !mounted) break;
        res = await appState.rescanFailedPages(res, _session.pages, engine: themeController.ocrEngine);
        if (!mounted) return;
      }
      if (res.ocr.isEmpty || res.parsed.needsManual) {
        await _showUnreadableModal();
        return;
      }
      // Fişi hangi motorun okuduğu: sonuçtaki motor (sunucu → paddleocr/custom; cihaz ya da ağ hatası geri dönüşü → mlkit).
      // Tercih edilen motordan değil, dönen sonuçtan alınır.
      final draft = _draftWith(ReceiptDraft.fromParsed(res.parsed)..ocrEngine = storedOcrEngineId(res.ocr.engine));
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ReceiptFormPage(initialDraft: draft)),
      );
    } on ApiException catch (e) {
      if (mounted) showError(context, e.message);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _scanning = false;
        });
      }
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

  Widget _viewfinder(BuildContext context) {
    final cam = _cam;
    switch (_camState) {
      case _CamState.ready when cam != null:
        return _LivePreview(
          camera: cam,
          flash: _flash,
          pageCount: _session.length,
          focusPoint: _focusPoint,
          onFocus: _focus,
          onFlash: _cycleFlash,
        );
      case _CamState.loading:
      case _CamState.paused:
      case _CamState.ready:
        return Center(child: CircularProgressIndicator(color: context.c.accent));
      case _CamState.denied:
      case _CamState.noCamera:
      case _CamState.unavailable:
        return _CameraFallback(
          state: _camState,
          busy: _busy,
          onSettings: _openSettings,
          onRetry: _openCamera,
          onGallery: _addFromGallery,
          onManual: _openManual,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final pages = _session.pages;
    final live = _camState == _CamState.ready;
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
            // E-fatura / e-arşiv / uygulama fişi gibi dijital belgeler kamerayla değil dosyadan eklenir.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Semantics(
                button: true,
                label: 'Dijital fiş veya PDF ekle',
                child: GestureDetector(
                  key: const Key('digital-import-button'),
                  onTap: _busy
                      ? null
                      : () => runDigitalImport(context, picker: widget.pickPdf, replace: true),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.surf2,
                      borderRadius: BorderRadius.circular(kRadiusSm),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.fileText, size: 18, color: c.ink),
                        const SizedBox(width: 8),
                        Text(
                          'Dijital Fiş / PDF Ekle',
                          style: FissioText.body(c, size: 14, weight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1918),
                  borderRadius: BorderRadius.circular(kRadius),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _viewfinder(context),
                    if (_scanning) const ColoredBox(color: Color(0xCC1A1918), child: _ScanBusy()),
                  ],
                ),
              ),
            ),
            if (pages.isNotEmpty) ...[
              _PageStrip(
                pages: pages,
                onRemove: _busy
                    ? null
                    : (i) => setState(() {
                          _session.removeAt(i);
                        }),
                onOpen: _busy ? null : _openPagesSheet,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: PrimaryButton(
                  label: pages.length == 1 ? 'Taramayı başlat' : 'Taramayı başlat (${pages.length} sayfa)',
                  icon: LucideIcons.scanLine,
                  busy: _scanning,
                  onPressed: _busy ? null : _scan,
                ),
              ),
            ],
            SizedBox(
              height: pages.isEmpty ? 130 : 104,
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
                      enabled: live && !_busy && !_session.isFull,
                      label: 'Fotoğraf çek',
                      child: GestureDetector(
                        onTap: live ? _capture : null,
                        child: Opacity(
                          opacity: live && !_session.isFull ? 1 : .4,
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
                    ),
                    Semantics(
                      button: true,
                      label: 'Sayfaları yönet',
                      child: GestureDetector(
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
                            child: Icon(LucideIcons.layers, size: 22, color: pages.isEmpty ? c.mute : c.ink),
                          ),
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

/// Canlı önizleme + hizalama kılavuzu + flaş düğmesi + dokunarak odak.
class _LivePreview extends StatelessWidget {
  const _LivePreview({
    required this.camera,
    required this.flash,
    required this.pageCount,
    required this.focusPoint,
    required this.onFocus,
    required this.onFlash,
  });

  final ScanCameraController camera;
  final ScanFlash flash;
  final int pageCount;
  final Offset? focusPoint;
  final void Function(Offset local, Offset normalized) onFocus;
  final VoidCallback onFlash;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        final ratio = camera.aspectRatio;
        return Stack(
            fit: StackFit.expand,
            children: [
              // Dokunarak odak yalnızca önizleme katmanında; üstteki düğmelerin erişilebilirlik
              // düğümleri tek bir dokunma düğümüne birleşmesin diye katmanlar kardeş tutulur.
              ExcludeSemantics(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => onFocus(d.localPosition, _toPreviewPoint(d.localPosition, size, ratio)),
                  child: ClipRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(width: ratio * 1000, height: 1000, child: camera.buildPreview()),
                    ),
                  ),
                ),
              ),
              const IgnorePointer(child: _GuideFrame()),
              if (focusPoint != null)
                Positioned(
                  left: focusPoint!.dx - 28,
                  top: focusPoint!.dy - 28,
                  child: IgnorePointer(
                    child: Container(
                      key: const ValueKey('focus-ring'),
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: c.accent, width: 2),
                      ),
                    ),
                  ),
                ),
              if (pageCount > 0)
                Positioned(
                  top: 12,
                  left: 12,
                  child: IgnorePointer(child: _Pill('Sayfa $pageCount/${ScanSession.maxPages}')),
                ),
              Positioned(
                top: 12,
                right: 12,
                child: Semantics(
                  button: true,
                  label: 'Flaş: ${flash.label}',
                  excludeSemantics: true,
                  child: GestureDetector(
                    onTap: onFlash,
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0x99000000),
                        borderRadius: BorderRadius.circular(kRadiusPill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            switch (flash) {
                              ScanFlash.off => LucideIcons.zapOff,
                              ScanFlash.auto => LucideIcons.zap,
                              ScanFlash.torch => LucideIcons.flashlight,
                            },
                            size: 18,
                            color: flash == ScanFlash.off ? Colors.white : c.accent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            flash.label,
                            style: const TextStyle(
                              fontFamily: fontFamily,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const Positioned(
                left: 20,
                right: 20,
                bottom: 18,
                child: IgnorePointer(
                  child: Center(child: _Pill('Fişi çerçeveye hizalayın · odak için dokunun')),
                ),
              ),
            ],
        );
      },
    );
  }
}

/// Vizör içindeki dokunuşu, `BoxFit.cover` ile kırpılmış önizlemenin 0..1 koordinatına çevirir
/// (kırpılan taraf yüzünden vizör oranı ile önizleme oranı farklıdır).
Offset _toPreviewPoint(Offset p, Size box, double ratio) {
  if (box.isEmpty || ratio <= 0) return const Offset(.5, .5);
  const ph = 1000.0;
  final pw = ratio * ph;
  final scale = box.width / pw > box.height / ph ? box.width / pw : box.height / ph;
  final ox = (box.width - pw * scale) / 2;
  final oy = (box.height - ph * scale) / 2;
  return Offset(
    ((p.dx - ox) / (pw * scale)).clamp(0.0, 1.0),
    ((p.dy - oy) / (ph * scale)).clamp(0.0, 1.0),
  );
}

/// Yarı saydam karartma + accent köşe parantezleri: fişi kadrajlamaya yardım eder.
class _GuideFrame extends StatelessWidget {
  const _GuideFrame();

  static const _inset = EdgeInsets.fromLTRB(32, 64, 32, 72);

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
      key: const ValueKey('guide-frame'),
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _DimPainter(_inset)),
        Padding(
          padding: _inset,
          child: Stack(
            children: [
              corner(Alignment.topLeft),
              corner(Alignment.topRight),
              corner(Alignment.bottomLeft),
              corner(Alignment.bottomRight),
            ],
          ),
        ),
      ],
    );
  }
}

class _DimPainter extends CustomPainter {
  const _DimPainter(this.inset);
  final EdgeInsets inset;

  @override
  void paint(Canvas canvas, Size size) {
    final hole = inset.deflateRect(Offset.zero & size);
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(kRadiusSm)));
    canvas.drawPath(path, Paint()..color = const Color(0x55000000));
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.inset != inset;
}

/// Çekilen sayfaların küçük resimleri; her birinde silme düğmesi.
class _PageStrip extends StatelessWidget {
  const _PageStrip({required this.pages, required this.onRemove, required this.onOpen});

  final List<Uint8List> pages;
  final void Function(int index)? onRemove;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      height: 84,
      child: ListView.separated(
        key: const ValueKey('page-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
        itemCount: pages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) => SizedBox(
          width: 56,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: onOpen,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(pages[i], fit: BoxFit.cover, key: ValueKey('thumb-$i')),
                  ),
                ),
              ),
              Positioned(
                right: -6,
                top: -6,
                child: Semantics(
                  button: true,
                  label: 'Sayfa ${i + 1} sil',
                  child: GestureDetector(
                    onTap: onRemove == null ? null : () => onRemove!(i),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(color: c.danger, shape: BoxShape.circle),
                      child: const Icon(LucideIcons.x, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// İzin reddi / kamera yok / kullanılamıyor: çökmek yerine açıklama ve çıkış yolları.
class _CameraFallback extends StatelessWidget {
  const _CameraFallback({
    required this.state,
    required this.busy,
    required this.onSettings,
    required this.onRetry,
    required this.onGallery,
    required this.onManual,
  });

  final _CamState state;
  final bool busy;
  final Future<void> Function() onSettings;
  final VoidCallback onRetry;
  final VoidCallback onGallery;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final denied = state == _CamState.denied;
    final title = switch (state) {
      _CamState.denied => 'Kamera izni gerekli',
      _CamState.noCamera => 'Kamera bulunamadı',
      _ => 'Kamera açılamadı',
    };
    final message = switch (state) {
      _CamState.denied =>
        'Fişi uygulama içinde çekebilmek için kamera erişimine izin verin. '
            'İsterseniz galeriden fotoğraf seçebilir veya bilgileri elle girebilirsiniz.',
      _CamState.noCamera => 'Bu cihazda kullanılabilir bir kamera yok. Galeriden fotoğraf seçebilir veya bilgileri elle girebilirsiniz.',
      _ => 'Kamera şu anda kullanılamıyor. Tekrar deneyebilir, galeriden fotoğraf seçebilir veya bilgileri elle girebilirsiniz.',
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.cameraOff, size: 40, color: c.accent),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: fontFamily, fontSize: 13, color: Color(0xFFBDB9B8), height: 1.4),
            ),
            const SizedBox(height: 18),
            if (denied) ...[
              PrimaryButton(label: 'Ayarlardan izin ver', icon: LucideIcons.settings, onPressed: () => onSettings()),
              const SizedBox(height: 8),
            ],
            _FallbackAction('Tekrar dene', LucideIcons.refreshCw, onRetry),
            _FallbackAction('Galeriden seç', LucideIcons.images, busy ? null : onGallery),
            _FallbackAction('Manuel gir', LucideIcons.pencil, onManual),
          ],
        ),
      ),
    );
  }
}

class _FallbackAction extends StatelessWidget {
  const _FallbackAction(this.label, this.icon, this.onTap);
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18, color: Colors.white),
        label: Text(
          label,
          style: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600, color: Colors.white),
        ),
      );
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
