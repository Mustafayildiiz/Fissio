import 'dart:io';

import 'package:fissio_mobile/ocr/picked_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory base;
  late Directory cache;
  late Directory gallery;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('fissio_pick_');
    cache = await Directory('${base.path}/cache').create();
    gallery = await Directory('${base.path}/gallery').create();
  });

  tearDown(() async {
    await base.delete(recursive: true);
  });

  test('cache altındaki dosya okunur ve silinir', () async {
    final f = await File('${cache.path}/a.jpg').writeAsBytes([1, 2, 3]);
    final bytes = await readAndDelete(f.path, tempRoot: cache);
    expect(bytes, [1, 2, 3]);
    expect(await f.exists(), isFalse);
  });

  test('cache dışındaki (galeri) orijinal dosya okunur ama silinmez', () async {
    final f = await File('${gallery.path}/orijinal.jpg').writeAsBytes([9, 9]);
    final bytes = await readAndDelete(f.path, tempRoot: cache);
    expect(bytes, [9, 9]);
    expect(await f.exists(), isTrue);
  });

  test('".." ile cache dışına kaçan yol silinmez', () async {
    final f = await File('${gallery.path}/x.jpg').writeAsBytes([7]);
    final sneaky = '${cache.path}/../gallery/x.jpg';
    await readAndDelete(sneaky, tempRoot: cache);
    expect(await f.exists(), isTrue);
  });

  test('cache içinden dışarıya symlink verilirse hedef dosya silinmez', () async {
    final target = await File('${gallery.path}/t.jpg').writeAsBytes([5]);
    final link = Link('${cache.path}/link.jpg');
    try {
      await link.create(target.path);
    } on FileSystemException {
      return; // Windows'ta symlink yetkisi yoksa atla.
    }
    await readAndDelete(link.path, tempRoot: cache);
    expect(await target.exists(), isTrue);
  });

  test('okuma hata verse de çağrı hatayı iletir', () async {
    expect(
      () => readAndDelete('${cache.path}/yok.jpg', tempRoot: cache),
      throwsA(isA<FileSystemException>()),
    );
  });
}
