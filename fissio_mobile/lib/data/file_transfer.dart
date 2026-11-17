import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Dışa/içe aktarma için dosya paylaşma/seçme (eklentiler arayüzün arkasında: testlerde sahtesi verilir ve
/// `build()` içinde hiç çağrılmaz).
abstract class FileTransfer {
  /// Dosyayı paylaşım menüsüyle verir (Dosyalar'a kaydet, e-posta, mesajlaşma...).
  Future<void> share({required String filename, required Uint8List bytes, required String mimeType});

  /// Cihaza kaydet penceresini açar; kaydedildiyse true.
  Future<bool> saveToDevice({required String filename, required Uint8List bytes, required String mimeType});

  /// Kullanıcıya JSON/CSV yedek dosyası seçtirir; vazgeçerse null.
  Future<({String name, String text})?> pickBackup();
}

class PluginFileTransfer implements FileTransfer {
  const PluginFileTransfer();

  @override
  Future<void> share({required String filename, required Uint8List bytes, required String mimeType}) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}$filename');
    await f.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(f.path, mimeType: mimeType, name: filename)], subject: filename),
    );
  }

  @override
  Future<bool> saveToDevice({required String filename, required Uint8List bytes, required String mimeType}) async {
    final uri = await FilePicker.saveFile(fileName: filename, bytes: bytes, mimeType: mimeType);
    return uri != null;
  }

  @override
  Future<({String name, String text})?> pickBackup() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['json', 'csv']);
    if (f == null) return null;
    final len = await f.length();
    if (len != null && len > 20 * 1024 * 1024) throw const FormatException('Dosya çok büyük (en fazla 20 MB).');
    final bytes = await f.readAsBytes();
    return (name: f.name, text: utf8.decode(bytes, allowMalformed: true));
  }
}
