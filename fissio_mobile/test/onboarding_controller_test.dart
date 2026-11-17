import 'package:fissio_mobile/onboarding_controller.dart';
import 'package:fissio_mobile/theme_controller.dart' show PrefsStore;
import 'package:flutter_test/flutter_test.dart';

class _MemStore implements PrefsStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

class _BrokenStore implements PrefsStore {
  @override
  Future<String?> read(String key) => throw Exception('no storage');
  @override
  Future<void> write(String key, String value) => throw Exception('no storage');
}

void main() {
  test('yeni kayıtta onboarding açılır; gösterildikten sonra yeniden başlatmada bile açılmaz', () async {
    final store = _MemStore();
    final a = OnboardingController(store: store);
    expect(await a.shouldShowAfterSignUp('yeni@fissio.app'), isTrue);

    await a.markShownAtSignUp('yeni@fissio.app');
    await a.complete();

    // Uygulama yeniden başlatıldı: aynı depolama, yeni denetleyici.
    final b = OnboardingController(store: store);
    await b.load();
    expect(await b.shouldShowAfterSignUp('yeni@fissio.app'), isFalse);
  });

  test('bayrak hesap bazlıdır: başka bir yeni hesap yine rehberi görür', () async {
    final c = OnboardingController(store: _MemStore());
    await c.markShownAtSignUp('a@fissio.app');
    expect(await c.shouldShowAfterSignUp('a@fissio.app'), isFalse);
    expect(await c.shouldShowAfterSignUp('b@fissio.app'), isTrue);
  });

  test('atlanan kayıt da tekrar otomatik açılmaz', () async {
    final store = _MemStore();
    final a = OnboardingController(store: store);
    await a.markShownAtSignUp('x@fissio.app'); // akış ekrana gelince yazılır
    await a.skip();

    final b = OnboardingController(store: store);
    await b.load();
    expect(await b.shouldShowAfterSignUp('x@fissio.app'), isFalse);
  });

  test('mevcut kullanıcı girişi denetleyiciye dokunmaz: hiçbir bayrak yazılmaz', () async {
    final store = _MemStore();
    final c = OnboardingController(store: store);
    await c.load();
    // AuthPage girişte shouldShowAfterSignUp'ı hiç çağırmaz; yalnızca yükleme yapılmıştır.
    expect(store.map, isEmpty);
  });

  test('complete/skip Ayarlar satırını etkilemez ve cihaz bayrağı yazmaz', () async {
    final store = _MemStore();
    final c = OnboardingController(store: store);
    await c.load();
    await c.skip();
    await c.complete();
    expect(store.map.containsKey(OnboardingController.legacyReplayUsedKey), isFalse);
  });

  test('depolama hata verirse çökmez', () async {
    final c = OnboardingController(store: _BrokenStore());
    await c.load();
    expect(await c.shouldShowAfterSignUp('x@fissio.app'), isTrue);
    await c.markShownAtSignUp('x@fissio.app');
    await c.complete();
  });
}
