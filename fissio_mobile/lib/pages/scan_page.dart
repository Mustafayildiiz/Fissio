import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt_form_page.dart';

/// Tara ekranı: Strategy Pattern ile yapılandırılan OCR motorunu (varsayılan: PaddleOCR PP-OCRv4 Mobile)
/// kullanarak fiş görselinden metin çıkarır, görseli bellekten siler (FR-2.3) ve önizleme formuna aktarır.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  late String _selectedEngine;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _selectedEngine = appState.ocrFactory.defaultEngine;
  }

  /// Test ve doğrulama için bellekte örnek bir fiş görseli (PNG) üretir.
  Future<Uint8List> _generateSampleReceiptPng() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(420, 320);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final tp = TextPainter(
      text: const TextSpan(
        text:
            'BIM BIRLESIK MAGAZALAR A.S.\n'
            'TARIH: 09.11.2026\n'
            'SUT 1L TAM YAGLI      34,50\n'
            'EKMEK 500G            15,00\n'
            'TOPLAM               *49,50',
        style: TextStyle(
          color: Color(0xFF000000),
          fontSize: 18,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 380);
    tp.paint(canvas, const Offset(20, 24));
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.width.toInt(), size.height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
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
          'Fiş net okunamadı, bilgileri manuel girmek ister misiniz?',
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
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ReceiptFormPage()),
      );
    }
  }

  Future<void> _runOcrScan() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final imageBytes = await _generateSampleReceiptPng();
      final res = await appState.scanAndParseReceipt(
        imageBytes,
        engine: _selectedEngine,
      );
      if (!mounted) return;
      if (res.ocr.isEmpty || res.parsed.needsManual) {
        await _showUnreadableModal();
        return;
      }
      final draft = ReceiptDraft.fromParsed(res.parsed);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ReceiptFormPage(initialDraft: draft),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final engines = appState.ocrFactory.availableEngines;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            BackTitle(
              'Fiş Oluştur',
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
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
                            eng == 'paddleocr' ? 'PP-OCRv4 Mobile' : 'Custom OCR',
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
                if (!scan) {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const ReceiptFormPage()),
                  );
                }
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
                child: Center(
                  child: _busy
                      ? const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: AppColors.accent),
                            SizedBox(height: 16),
                            Text(
                              'Fiş taranıyor ve ayrıştırılıyor...',
                              style: TextStyle(color: Colors.white, fontSize: 14),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.document_scanner_outlined,
                              size: 90,
                              color: AppColors.secondaryText,
                            ),
                            const SizedBox(height: 18),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 32),
                              child: Text(
                                'Aktif OCR Motoru: ${_selectedEngine == 'paddleocr' ? 'PaddleOCR (PP-OCRv4 Mobile)' : 'Custom OCR Engine'}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            PrimaryButton(
                              label: 'Fişi Tara',
                              compact: true,
                              onPressed: _runOcrScan,
                            ),
                          ],
                        ),
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
                    tooltip: 'Galeri',
                    onPressed: _busy ? null : _runOcrScan,
                    icon: const Icon(
                      Icons.image_outlined,
                      size: 32,
                      color: AppColors.secondaryText,
                    ),
                  ),
                  InkWell(
                    onTap: _busy ? null : _runOcrScan,
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
                  IconButton(
                    tooltip: 'Manuel giriş',
                    onPressed: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const ReceiptFormPage()),
                    ),
                    icon: const Icon(
                      Icons.receipt_long,
                      size: 32,
                      color: AppColors.secondaryText,
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
