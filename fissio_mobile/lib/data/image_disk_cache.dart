import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'dart:convert' show utf8;

/// Sunucudan görsel baytlarını çeker (JWT başlığıyla); başarısızlıkta null. Testlerde değiştirilir.
typedef ImageFetcher = Future<Uint8List?> Function(String url, Map<String, String> headers);

Future<Uint8List?> _httpFetch(String url, Map<String, String> headers) async {
  try {
    final r = await http.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 20));
    return r.statusCode == 200 && r.bodyBytes.isNotEmpty ? r.bodyBytes : null;
  } catch (_) {
    return null;
  }
}

/// Fiş fotoğrafları ve profil avatarları için disk önbelleği: `Image.network` yalnızca bellekte önbellekler, bu yüzden
/// uygulama yeniden açılınca ya da çevrimdışıyken görseller kayboluyordu. Adres (görsel kimliği / avatar sürümü içerir)
/// değişmez içerik tanımladığı için anahtar adrestir. Önbellek hesaba aittir: çıkışta ve hesap silmede [clear] ile
/// SİLİNİR (finansal fotoğraflar sonraki kullanıcıya kalmaz). Toplam boyut [maxBytes]'ı aşarsa en eski dosyalar silinir.
class ImageDiskCache {
  ImageDiskCache({Future<Directory> Function()? baseDir, ImageFetcher? fetcher, this.maxBytes = 120 << 20})
    : _baseDir = baseDir ?? getApplicationSupportDirectory,
      fetch = fetcher ?? _httpFetch;

  /// Uygulama genelinde paylaşılan örnek (widget'lar bunu kullanır; testler `ImageDiskCache.instance = ...` ile değiştirir).
  static ImageDiskCache instance = ImageDiskCache();

  final Future<Directory> Function() _baseDir;
  ImageFetcher fetch;
  final int maxBytes;
  final Map<String, Uint8List> _mem = {};
  Directory? _dir;

  Future<Directory> _cacheDir() async {
    final d = _dir ??= Directory('${(await _baseDir()).path}${Platform.pathSeparator}fissio_img_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _name(String url) => sha1.convert(utf8.encode(url)).toString();

  /// Önce bellek, sonra disk, sonra ağ. Ağdan gelen bayt diske yazılır. Hiçbiri yoksa null.
  Future<Uint8List?> load(String url, Map<String, String> headers) async {
    final hit = _mem[url];
    if (hit != null) return hit;
    try {
      final f = File('${(await _cacheDir()).path}${Platform.pathSeparator}${_name(url)}');
      if (await f.exists()) {
        final b = await f.readAsBytes();
        if (b.isNotEmpty) return _remember(url, b);
      }
    } catch (_) {
      // disk okunamadı: ağdan dene
    }
    final bytes = await fetch(url, headers);
    if (bytes == null) return null;
    try {
      final dir = await _cacheDir();
      await File('${dir.path}${Platform.pathSeparator}${_name(url)}').writeAsBytes(bytes, flush: true);
      await _trim(dir);
    } catch (_) {
      // yazılamadı: görsel yine de gösterilir
    }
    return _remember(url, bytes);
  }

  Uint8List _remember(String url, Uint8List b) {
    if (_mem.length >= 40) _mem.remove(_mem.keys.first);
    _mem[url] = b;
    return b;
  }

  Future<void> _trim(Directory dir) async {
    final files = <(File, FileStat)>[];
    var total = 0;
    await for (final e in dir.list()) {
      if (e is File) {
        final st = await e.stat();
        files.add((e, st));
        total += st.size;
      }
    }
    if (total <= maxBytes) return;
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (f, st) in files) {
      if (total <= maxBytes) break;
      try {
        await f.delete();
        total -= st.size;
      } catch (_) {}
    }
  }

  /// Tüm önbelleği (bellek + disk) siler: çıkış / hesap silme.
  Future<void> clear() async {
    _mem.clear();
    try {
      final d = await _cacheDir();
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}

/// Disk önbellekli ağ görseli: JWT başlıklı, çevrimdışıyken önbellekten, yüklenirken gösterge, hatada [error].
class CachedNetImage extends StatefulWidget {
  const CachedNetImage({
    super.key,
    required this.url,
    required this.headers,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.gaplessPlayback = false,
    this.loading,
    required this.error,
  });
  final String url;
  final Map<String, String> headers;
  final double? width;
  final double? height;
  final BoxFit fit;
  final bool gaplessPlayback;
  final Widget? loading;
  final WidgetBuilder error;

  @override
  State<CachedNetImage> createState() => _CachedNetImageState();
}

class _CachedNetImageState extends State<CachedNetImage> {
  late Future<Uint8List?> _future = ImageDiskCache.instance.load(widget.url, widget.headers);

  @override
  void didUpdateWidget(CachedNetImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _future = ImageDiskCache.instance.load(widget.url, widget.headers);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes != null) {
          return Image.memory(
            bytes,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            gaplessPlayback: widget.gaplessPlayback,
            errorBuilder: (c, _, _) => widget.error(c),
          );
        }
        if (snap.connectionState != ConnectionState.done) {
          return widget.loading ??
              SizedBox(
                width: widget.width,
                height: widget.height,
                child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
        }
        return widget.error(context);
      },
    );
  }
}
