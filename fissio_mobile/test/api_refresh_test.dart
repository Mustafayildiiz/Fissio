import 'dart:typed_data';

import 'package:fissio_mobile/api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

ApiClient _client(FakeBackend b, {void Function()? onUnauthorized, void Function(AuthTokens?)? onTokens}) => ApiClient(
  client: b.client,
  device: FakeDevice(),
  authBase: 'http://fake-auth',
  expenseBase: 'http://fake-expense',
  onUnauthorized: onUnauthorized,
  onTokensChanged: onTokens,
);

void main() {
  late FakeBackend backend;

  setUp(() {
    backend = FakeBackend()..addUser('a@b.co', 'Passw0rd1');
  });

  Future<ApiClient> loggedIn({void Function()? onUnauthorized, void Function(AuthTokens?)? onTokens}) async {
    final api = _client(backend, onUnauthorized: onUnauthorized, onTokens: onTokens);
    final s = await api.login('a@b.co', 'Passw0rd1');
    api.setTokens(s.tokens);
    return api;
  }

  test('401 gelince sessizce yenilenir ve istek tekrarlanır; kullanıcı düşmez', () async {
    var expired = 0;
    final changes = <AuthTokens?>[];
    final api = await loggedIn(onUnauthorized: () => expired++, onTokens: changes.add);
    final first = api.tokens!;
    // Sunucu access token'ı geçersiz sayar (süresi doldu): refresh token geçerli.
    backend.log.clear();
    backend.expireAccess(first.access);

    final cats = await api.categories();
    expect(cats, isNotEmpty);
    expect(expired, 0, reason: 'oturum düşmemeli');
    expect(api.tokens!.access, isNot(first.access));
    expect(api.tokens!.refresh, isNot(first.refresh), reason: 'refresh token rotasyonu');
    expect(backend.refreshCalls, 1);
    // Sıra: categories (401) -> refresh -> categories (200)
    expect(backend.log.map((l) => l.path), ['/categories', '/auth/refresh', '/categories']);
    expect(changes.last, same(api.tokens));
  });

  test('eşzamanlı 401\'ler TEK refresh isteğini paylaşır (refresh token tek kullanımlık)', () async {
    final api = await loggedIn();
    backend.expireAccess(api.tokens!.access);
    final results = await Future.wait([api.categories(), api.categories(), api.profiles()]);
    expect(results.length, 3);
    expect(backend.refreshCalls, 1);
  });

  test('refresh reddedilirse oturum biter (onUnauthorized) ve token\'lar temizlenir', () async {
    var expired = 0;
    final changes = <AuthTokens?>[];
    final api = await loggedIn(onUnauthorized: () => expired++, onTokens: changes.add);
    backend.expireAccess(api.tokens!.access);
    backend.rejectRefresh = true;

    await expectLater(api.categories(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
    expect(expired, 1);
    expect(api.tokens, isNull);
    expect(changes.last, isNull);
  });

  test('refresh geçici sunucu hatası (5xx) verirse oturum KORUNUR; istek bu hatayla düşer', () async {
    var expired = 0;
    final api = await loggedIn(onUnauthorized: () => expired++);
    final before = api.tokens!;
    backend.expireAccess(before.access);
    backend.failPaths.add('POST /auth/refresh'); // 500
    await expectLater(api.categories(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 500)));
    expect(expired, 0, reason: 'geçici 5xx oturumu bitirmemeli');
    expect(api.tokens, isNotNull);
    expect(api.tokens!.refresh, before.refresh);
    // Sunucu düzelince aynı refresh token ile devam edilir.
    backend.failPaths.clear();
    expect(await api.categories(), isNotEmpty);
    expect(expired, 0);
  });

  test('refresh sırasında ağ yoksa oturum KORUNUR (çevrimdışı kullanıcıyı düşürme)', () async {
    var expired = 0;
    final api = await loggedIn(onUnauthorized: () => expired++);
    final before = api.tokens!;
    backend.expireAccess(before.access);
    backend.afterRequest = (m, p) {
      if (p == '/categories') backend.offline = true; // ilk 401'den sonra bağlantı kopar
    };
    await expectLater(api.categories(), throwsA(isA<ApiException>().having((e) => e.network, 'network', true)));
    expect(expired, 0);
    expect(api.tokens, isNotNull);
    expect(api.tokens!.refresh, before.refresh, reason: 'refresh token harcanmamalı');
    // Bağlantı gelince aynı refresh token ile devam edilir.
    backend.offline = false;
    backend.afterRequest = null;
    expect((await api.categories()), isNotEmpty);
    expect(expired, 0);
  });

  test('session_revoked 401: yenileme denenmez, oturum hemen biter', () async {
    var expired = 0;
    final api = await loggedIn(onUnauthorized: () => expired++);
    backend.revokeSession(api.tokens!.access);
    await expectLater(api.categories(), throwsA(isA<ApiException>()));
    expect(backend.refreshCalls, 0);
    expect(expired, 1);
  });

  test('süresi dolmaya yakın access token istekten ÖNCE yenilenir', () async {
    final api = ApiClient(
      client: backend.client,
      device: FakeDevice(),
      authBase: 'http://fake-auth',
      expenseBase: 'http://fake-expense',
    );
    final s = await api.login('a@b.co', 'Passw0rd1');
    // 30 sn kala: eşik (90 sn) altında.
    api.setTokens(AuthTokens(access: s.tokens.access, refresh: s.tokens.refresh, expiresAt: DateTime.now().add(const Duration(seconds: 30))));
    backend.log.clear();
    await api.categories();
    expect(backend.log.map((l) => l.path), ['/auth/refresh', '/categories'], reason: '401 beklenmeden yenilenmeli');
  });

  test('ensureFresh görsel başlıklarının bayatlamaması için access token\'ı önceden yeniler', () async {
    final api = await loggedIn();
    api.setTokens(AuthTokens(access: api.tokens!.access, refresh: api.tokens!.refresh, expiresAt: DateTime.now().add(const Duration(seconds: 20))));
    final old = api.authHeaders['Authorization'];
    await api.ensureFresh();
    expect(api.authHeaders['Authorization'], isNot(old));
  });

  test('çok parçalı (fotoğraf) yükleme de 401\'de yeniden kurulup tekrarlanır', () async {
    final api = await loggedIn();
    final pid = (await api.profiles()).first.serverId!;
    final exp = await api.createExpense({
      'merchant': 'BIM', 'amount': 5, 'date': '2026-05-01', 'category_id': 1, 'profile_id': pid, 'items': [], 'note': '',
    });
    backend.expireAccess(api.tokens!.access);
    final ids = await api.uploadImages(exp.id, [Uint8List.fromList([1, 2, 3])]);
    expect(ids, hasLength(1));
    expect(backend.refreshCalls, 1);
  });

  test('hata kodları Türkçe mesaja çevrilir ve retry_after taşınır', () async {
    final api = _client(backend);
    await expectLater(
      api.verifyEmail('a@b.co', '000000'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_code').having((e) => e.message, 'message', contains('Kod hatalı'))),
    );
    await expectLater(
      api.verifyEmail('a@b.co', 'EXPIRED'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('süresi doldu'))),
    );
    await expectLater(
      api.login('a@b.co', 'yanlis'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'E-posta veya şifre hatalı.')),
    );
  });
}
