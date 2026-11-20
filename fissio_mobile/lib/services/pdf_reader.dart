import 'package:flutter/services.dart';

import 'plugin_log.dart';

/// PDF dosyasını okuyan port (cihaz içi; hiçbir veri cihazdan çıkmaz). Testlerde sahtesi verilir.
///
/// Gerçek okuyucu yerel köprüdür (`fissio/pdf`): Android'de PdfBox-Android (metin katmanı) + `PdfRenderer` (sayfa
/// görseli), iOS'ta PDFKit. Dart'a yerel-derlemeli bir PDF paketi (pdfium) bilerek eklenmedi: `flutter test` her
/// makinede C derleyicisi gerektirirdi.
abstract class PdfReader {
  /// Her sayfanın metin katmanı (taranmış PDF'te boş/kısa). En fazla [maxPages] sayfa. Açılamazsa [PdfReadException].
  Future<List<String>> readText(String path, {int maxPages = 6});

  /// Sayfaları görsele (PNG) çevirir; taranmış PDF OCR'a düşerken kullanılır. En fazla [maxPages] sayfa.
  Future<List<Uint8List>> renderPages(String path, {int maxPages = 6});
}

class PdfReadException implements Exception {
  PdfReadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `fissio/pdf` yerel köprüsü: `readText` → `List<String>`, `renderPages` → `List<Uint8List>` (PNG).
class ChannelPdfReader implements PdfReader {
  const ChannelPdfReader();
  static const _channel = MethodChannel('fissio/pdf');

  Future<T> _call<T>(String method, String path, int maxPages, String failure) async {
    try {
      final res = await _channel.invokeMethod<T>(method, {'path': path, 'maxPages': maxPages});
      if (res == null) throw PdfReadException(failure);
      return res;
    } on PdfReadException {
      rethrow;
    } on PlatformException catch (e) {
      pluginWarn('PDF okunamadı ($method)', e);
      throw PdfReadException(e.code == 'encrypted'
          ? 'PDF parola korumalı; açılamadı.'
          : 'PDF dosyası açılamadı. Dosya bozuk olabilir.');
    } on MissingPluginException catch (e) {
      pluginWarn('PDF köprüsü yok', e);
      throw PdfReadException('PDF okuyucu bu cihazda kullanılamıyor.');
    } catch (e) {
      pluginWarn('PDF okunamadı ($method)', e);
      throw PdfReadException(failure);
    }
  }

  @override
  Future<List<String>> readText(String path, {int maxPages = 6}) async =>
      (await _call<List<Object?>>('readText', path, maxPages, 'PDF metni okunamadı.')).cast<String>();

  @override
  Future<List<Uint8List>> renderPages(String path, {int maxPages = 6}) async {
    final pages = (await _call<List<Object?>>('renderPages', path, maxPages, 'PDF sayfaları görüntüye çevrilemedi.'))
        .cast<Uint8List>();
    if (pages.isEmpty) throw PdfReadException('PDF sayfaları görüntüye çevrilemedi.');
    return pages;
  }
}

/// Testler ve eklentisiz ortamlar için: hiçbir şey okuyamaz.
class UnavailablePdfReader implements PdfReader {
  const UnavailablePdfReader();
  @override
  Future<List<String>> readText(String path, {int maxPages = 6}) async =>
      throw PdfReadException('PDF okuyucu bu cihazda kullanılamıyor.');
  @override
  Future<List<Uint8List>> renderPages(String path, {int maxPages = 6}) async =>
      throw PdfReadException('PDF okuyucu bu cihazda kullanılamıyor.');
}

/// Uygulamanın PDF okuyucusu (testlerde `FakePdfReader` ile değiştirilir).
PdfReader pdfReader = const ChannelPdfReader();
