import 'dart:io';
import 'dart:typed_data';

import 'package:fissio_mobile/data/image_disk_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

void main() {
  late Directory tmp;
  late int fetches;
  late bool online;
  late ImageDiskCache cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fissio_img_test');
    fetches = 0;
    online = true;
    cache = ImageDiskCache(
      baseDir: () async => tmp,
      fetcher: (url, headers) async {
        fetches++;
        if (!online) return null;
        return Uint8List.fromList([1, 2, 3, url.length, url.codeUnits.last]);
      },
    );
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('ilk yükleme ağdan; sonra bellekten; yeniden açılışta (yeni örnek) diskten, çevrimdışıyken de', () async {
    const url = 'http://x/expenses/1/images/5';
    expect(await cache.load(url, {'Authorization': 'Bearer t'}), isNotNull);
    expect(fetches, 1);
    expect(await cache.load(url, {}), isNotNull);
    expect(fetches, 1, reason: 'bellek önbelleği');

    // Uygulama yeniden açıldı + çevrimdışı: ağa hiç gidilmez, disk yeter.
    online = false;
    final reopened = ImageDiskCache(baseDir: () async => tmp, fetcher: (u, h) async => fail('ağa gidilmemeli'));
    expect(await reopened.load(url, {}), Uint8List.fromList([1, 2, 3, url.length, url.codeUnits.last]));
  });

  test('çevrimdışı ve önbellekte yoksa null (hata görseli); başarısız çekim diske yazılmaz', () async {
    online = false;
    expect(await cache.load('http://x/expenses/2/images/9', {}), isNull);
    online = true;
    expect(await cache.load('http://x/expenses/2/images/9', {}), isNotNull, reason: 'sonraki denemede yine ağdan denenir');
  });

  test('farklı avatar sürümü farklı adrestir (sürüm değişince eski önbellek kullanılmaz)', () async {
    final a = await cache.load('http://x/profiles/1/avatar?v=1', {});
    final b = await cache.load('http://x/profiles/1/avatar?v=2', {});
    expect(fetches, 2);
    expect(a, isNot(equals(b)));
  });

  test('clear: bellek ve disk silinir (çıkış / hesap silme); sonra çevrimdışıyken görsel yok', () async {
    const url = 'http://x/expenses/1/images/5';
    await cache.load(url, {});
    await cache.clear();
    online = false;
    expect(await cache.load(url, {}), isNull);
    final fresh = ImageDiskCache(baseDir: () async => tmp, fetcher: (u, h) async => null);
    expect(await fresh.load(url, {}), isNull, reason: 'disk de boş');
  });

  test('boyut sınırı aşılınca en eski dosyalar silinir', () async {
    final small = ImageDiskCache(
      baseDir: () async => tmp,
      maxBytes: 10,
      fetcher: (url, h) async => Uint8List(6),
    );
    await small.load('http://x/1', {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await small.load('http://x/2', {});
    final dir = Directory('${tmp.path}${Platform.pathSeparator}fissio_img_cache');
    final files = dir.listSync().whereType<File>().toList();
    expect(files.length, 1, reason: '6+6 > 10 bayt: eski olan atılır');
  });

  test('çıkış yapınca önbellek (finansal fotoğraflar) silinir', () async {
    final prev = ImageDiskCache.instance;
    addTearDown(() => ImageDiskCache.instance = prev);
    ImageDiskCache.instance = cache;
    const url = 'http://x/expenses/1/images/5';
    await cache.load(url, {});
    final h = Harness();
    await h.signIn('ali@x.co');
    await h.app.logout();
    online = false;
    expect(await cache.load(url, {}), isNull);
  });
}
