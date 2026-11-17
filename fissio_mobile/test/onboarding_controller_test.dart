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
    expect(c.replayAvailable, isTrue); // rehberi hiç görmemiş → Ayarlar'da erişilebilir
  });

  test('Ayarlar satırı: taze → görünür, atla → görünür kalır, tamamla → kalıcı gizli', () async {
    final store = _MemStore();
    final fresh = OnboardingController(store: store);
    await fresh.load();
    expect(fresh.replayAvailable, isTrue);

    await fresh.skip();
    expect(fresh.replayAvailable, isTrue);
    final afterSkip = OnboardingController(store: store);
    await afterSkip.load();
    expect(afterSkip.replayAvailable, isTrue);

    await afterSkip.complete();
    expect(afterSkip.replayAvailable, isFalse);
    final afterComplete = OnboardingController(store: store);
    await afterComplete.load();
    expect(afterComplete.replayAvailable, isFalse);
  });

  test('Ayarlar\'dan açma satırı anında ve kalıcı gizler; dinleyiciler bilgilendirilir', () async {
    final store = _MemStore();
    final c = OnboardingController(store: store);
    await c.load();
    var notified = 0;
    c.addListener(() => notified++);

    await c.markReplayOpened();
    expect(c.replayAvailable, isFalse);
    expect(notified, 1);

    final restarted = OnboardingController(store: store);
    await restarted.load();
    expect(restarted.replayAvailable, isFalse);
  });

  test('depolama hata verirse çökmez; bellek durumu korunur', () async {
    final c = OnboardingController(store: _BrokenStore());
    await c.load();
    expect(c.replayAvailable, isTrue);
    expect(await c.shouldShowAfterSignUp('x@fissio.app'), isTrue);
    await c.markShownAtSignUp('x@fissio.app');
    await c.markReplayOpened();
    expect(c.replayAvailable, isFalse);
  });
}
