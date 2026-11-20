import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt_form_page.dart';

/// PDF seçer ve yerel dosya yolunu döner (iptal = null). Testlerde değiştirilebilir.
typedef PdfPicker = Future<String?> Function();

const _maxPdfBytes = 20 * 1024 * 1024;

/// Cihazdan `.pdf` seçer. `content://` gibi dosya yolu olmayan kaynaklar geçici dosyaya kopyalanır.
Future<String?> pickPdfFile() async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['pdf']);
  if (f == null) return null;
  final len = await f.length();
  if (len != null && len > _maxPdfBytes) throw ApiException('PDF çok büyük (en fazla 20 MB).');
  final path = f.path;
  if (path != null) return path;
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/fissio_import_${DateTime.now().millisecondsSinceEpoch}.pdf');
  await file.writeAsBytes(await f.readAsBytes(), flush: true);
  return file.path;
}

/// Dijital fiş / e-fatura (PDF) içe aktarma akışı: dosyayı ([path] yoksa [picker] ile seçtirerek) okur, taslağı hazırlar
/// ve fiş formunu açar. Hata ya da mükerrer fatura kullanıcıya iletisiyle gösterilir; akış sessizce biter.
///
/// [replace] true ise (ScanPage'den) tarama sayfasının yerine, değilse üstüne açılır.
Future<void> runDigitalImport(
  BuildContext context, {
  String? path,
  PdfPicker picker = pickPdfFile,
  bool replace = false,
}) async {
  final nav = Navigator.of(context);
  final messenger = context;
  String? file = path;
  try {
    file ??= await picker();
  } on ApiException catch (e) {
    if (messenger.mounted) showMessage(messenger, e.message);
    return;
  } catch (_) {
    if (messenger.mounted) showMessage(messenger, 'Dosya seçilemedi. Ayarlardan dosya erişimine izin verin.');
    return;
  }
  if (file == null || !messenger.mounted) return;

  // Okuma sürerken ikinci dokunuşu engelleyen basit ilerleme penceresi.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator(color: ctx.c.accent)),
    ),
  );
  ReceiptDraft? draft;
  String? error;
  try {
    draft = await appState.readDigitalReceipt(file);
  } on ApiException catch (e) {
    error = e.message;
  } catch (_) {
    error = 'PDF okunamadı. Bilgileri elle girebilirsiniz.';
  }
  if (!messenger.mounted) return;
  nav.pop(); // ilerleme penceresi
  if (draft == null) {
    showMessage(messenger, error ?? 'PDF okunamadı.');
    return;
  }
  final route = MaterialPageRoute<void>(builder: (_) => ReceiptFormPage(initialDraft: draft));
  if (replace) {
    await nav.pushReplacement(route);
  } else {
    await nav.push(route);
  }
}
