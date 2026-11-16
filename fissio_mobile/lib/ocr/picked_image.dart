import 'dart:io';
import 'dart:typed_data';

/// Seçilen fotoğrafı okur; dosya yalnızca uygulamanın geçici (cache) dizinindeyse siler (FR-2.3).
///
/// Galeri seçici bazen önbellek kopyası yerine kullanıcının ORİJİNAL dosyasının yolunu
/// döndürür; bu durumda dosyaya asla dokunulmaz. Kanonik yol (symlink ve `..` çözülmüş)
/// `tempRoot` altında değilse silinmez. `tempRoot` varsayılanı [Directory.systemTemp]
/// (Android'de uygulamanın cache dizini).
Future<Uint8List> readAndDelete(String path, {Directory? tempRoot}) async {
  final file = File(path);
  try {
    return await file.readAsBytes();
  } finally {
    try {
      if (await _isUnder(file, tempRoot ?? Directory.systemTemp)) {
        await file.delete();
      }
    } catch (_) {
      // Silme başarısızsa tarama akışı bozulmasın.
    }
  }
}

Future<bool> _isUnder(File file, Directory root) async {
  if (!await file.exists()) return false;
  final canonicalFile = await file.resolveSymbolicLinks();
  final canonicalRoot = await root.resolveSymbolicLinks();
  final sep = Platform.pathSeparator;
  final prefix = canonicalRoot.endsWith(sep) ? canonicalRoot : '$canonicalRoot$sep';
  return canonicalFile.startsWith(prefix);
}
