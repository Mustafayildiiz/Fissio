import 'dart:typed_data';

import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/app_state.dart';
import 'package:fissio_mobile/data/sync_service.dart';
import 'package:fissio_mobile/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

ReceiptDraft _draft(String merchant, {double amount = 10, List<Uint8List>? images, int? id, String? uid}) => ReceiptDraft(
  id: id,
  clientUid: uid,
  merchant: merchant,
  categoryId: 1,
  items: [ExpenseItem('kalem', amount, categoryId: 1)],
  pendingImages: images ?? [],
);

Uint8List _img() => Uint8List.fromList([1, 2, 3, 4]);

/// Koşul sağlanana dek olay döngüsünü döndürür (arka plan flush'ı için).
Future<void> _until(bool Function() cond, {String? reason}) async {
  for (var i = 0; i < 500; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Koşul gerçekleşmedi${reason == null ? '' : ': $reason'}');
}

void main() {
  _avatarTests();
  late Harness h;

  setUp(() => h = Harness());

  group('hesap izolasyonu ve önbellek temizliği', () {
    test('iki farklı hesabın profilleri ve fişleri tamamen izole; çıkışta bellek sıfırlanır', () async {
      await h.signIn('ali@x.co');
      expect(h.app.profiles.map((p) => p.name), ['Kişisel'], reason: 'ilk profil otomatik');
      await h.app.createProfile('Ev');
      expect(h.app.profiles.map((p) => p.name), ['Kişisel', 'Ev']);
      expect(h.app.activeProfile!.name, 'Ev');
      final res = await h.app.saveDraft(_draft('BIM Ali'));
      expect(res.queued, isFalse);
      expect(h.app.expenses.map((e) => e.merchant), ['BIM Ali']);

      await h.app.logout();
      expect(h.app.user, isNull);
      expect(h.app.profiles, isEmpty);
      expect(h.app.expenses, isEmpty);
      expect(h.app.categories, isEmpty);
      expect(h.app.activeProfileId, isNull);
      expect(h.app.loggedIn, isFalse);

      // Başka hesap: Ali'nin hiçbir verisi görünmez, aktif profil seçimi Ali'den kalmaz.
      await h.signIn('veli@x.co');
      expect(h.app.profiles.map((p) => p.name), ['Kişisel']);
      expect(h.app.expenses, isEmpty);
      expect(h.app.activeProfile!.serverId, isNot(h.backend.user('ali@x.co').profiles.first['id']));
      await h.app.createProfile('İş');
      await h.app.saveDraft(_draft('Shell Veli'));
      expect(h.app.profiles.map((p) => p.name), ['Kişisel', 'İş']);

      // Sunucuda iki hesap ayrı; Ali geri gelince kendi verisini görür.
      await h.app.logout();
      await h.signIn('ali@x.co');
      expect(h.app.profiles.map((p) => p.name), ['Kişisel', 'Ev']);
      expect(h.app.expenses, isEmpty, reason: 'aktif profil: Kişisel (Ev değil) — Ali\'nin fişi Ev profilinde');
      await h.app.selectProfile(h.app.profiles.firstWhere((p) => p.name == 'Ev'));
      expect(h.app.expenses.map((e) => e.merchant), ['BIM Ali']);
      expect(h.backend.expensesOf('veli@x.co').map((e) => e['merchant']), ['Shell Veli']);
    });

    test('çıkışta token\'lar, kullanıcı ve aktif profil silinir; şifre hiçbir yerde saklanmaz', () async {
      await h.signIn('ali@x.co', password: 'Passw0rd1');
      final uid = h.app.user!.id;
      expect(h.prefs.data.keys, containsAll(['auth_tokens', 'auth_user', 'active_profile:$uid']));
      expect(h.prefs.data.values.any((v) => v.contains('Passw0rd1')), isFalse, reason: 'düz metin şifre saklanmamalı');

      await h.app.logout();
      expect(h.prefs.data.containsKey('auth_tokens'), isFalse);
      expect(h.prefs.data.containsKey('auth_user'), isFalse);
      expect(h.prefs.data.containsKey('active_profile:$uid'), isFalse);
      expect(h.app.api.token, isNull);
      // Sunucuda bu cihazın oturumu kapandı (eski access token artık geçersiz).
      expect(h.backend.writes, contains('POST /auth/logout'));
    });

    test('eski sürümün düz metin şifreli profil kayıtları ilk açılışta silinir', () async {
      h.prefs.data['profiles_v2'] = '[{"email":"p_1@fissio.local","password":"fissio_1_pw"}]';
      h.prefs.data['jwt'] = 'old';
      h.prefs.data['active_profile_v2'] = 'x';
      expect(await h.app.restoreSession(), isFalse);
      expect(h.prefs.data.containsKey('profiles_v2'), isFalse);
      expect(h.prefs.data.containsKey('jwt'), isFalse);
      expect(h.prefs.data.containsKey('active_profile_v2'), isFalse);
    });

    test('oturum geri yükleme: çevrimdışıyken son hesapla devam, iptal edilmişse yerel oturum temizlenir', () async {
      await h.signIn('ali@x.co');
      await h.app.createProfile('Ev');

      // Yeni açılış (aynı depolar), sunucuya ulaşılamıyor.
      final offlineApp = Harness(backend: h.backend, prefs: h.prefs, local: h.local);
      h.backend.offline = true;
      expect(await offlineApp.app.restoreSession(), isTrue);
      await offlineApp.app.restoreSettled;
      expect(offlineApp.app.email, 'ali@x.co');
      expect(offlineApp.app.profiles.map((p) => p.name), containsAll(['Kişisel', 'Ev']), reason: 'önbellekten');

      // Sunucu oturumu iptal etti (uzaktan çıkış): geri yüklemede düşer.
      h.backend.offline = false;
      h.backend.revokeSession(h.app.api.token!);
      final revoked = Harness(backend: h.backend, prefs: h.prefs, local: h.local);
      var expired = 0;
      revoked.app.onSessionExpired = () => expired++;
      // Önbellek varken açılış doğrulamayı beklemez (hemen true); iptal arka planda anlaşılır ve giriş ekranına dönülür.
      expect(await revoked.app.restoreSession(), isTrue, reason: 'önbellekli veri hemen gösterilir');
      await revoked.app.restoreSettled;
      await Future<void>.delayed(Duration.zero);
      expect(revoked.app.loggedIn, isFalse);
      expect(expired, 1, reason: 'oturum düşünce giriş ekranına dönüş bildirilir');
      expect(h.prefs.data.containsKey('auth_tokens'), isFalse);
    });

    test('geçici sunucu hatası (me() 500): önbellekli ve önbelleksiz açılışta oturum DÜŞMEZ', () async {
      await h.signIn('ali@x.co');
      // Önbellekli açılış.
      final cached = Harness(backend: h.backend, prefs: h.prefs, local: h.local);
      var expired = 0;
      cached.app.onSessionExpired = () => expired++;
      h.backend.failPaths.add('GET /auth/me');
      expect(await cached.app.restoreSession(), isTrue);
      await cached.app.restoreSettled;
      await Future<void>.delayed(Duration.zero);
      expect(cached.app.loggedIn, isTrue);
      expect(expired, 0);
      expect(h.prefs.data.containsKey('auth_tokens'), isTrue);

      // Önbelleksiz açılış (yerel veri yok).
      final bare = Harness(backend: h.backend, prefs: h.prefs);
      expect(await bare.app.restoreSession(), isTrue, reason: 'me() 500 oturumu bitirmez');
      expect(h.prefs.data.containsKey('auth_tokens'), isTrue);
    });

    test('hesap silme: sunucu hesabı, yerel dosyalar ve tercihler kalıcı temizlenir', () async {
      await h.signIn('ali@x.co');
      final uid = h.app.user!.id;
      h.backend.offline = true;
      await h.app.saveDraft(_draft('Cevrimdisi', images: [_img()]));
      h.backend.offline = false;
      expect(h.local.hasData(uid), isTrue);
      expect(h.local.images, isNotEmpty);

      await expectLater(h.app.deleteAccount('yanlis'), throwsA(isA<ApiException>()));
      expect(h.app.loggedIn, isTrue, reason: 'yanlış şifre hesabı silmez');
      await h.app.deleteAccount('Passw0rd1');
      expect(h.local.hasData(uid), isFalse);
      expect(h.local.images, isEmpty);
      expect(h.prefs.data.keys.where((k) => k.contains(':$uid')), isEmpty);
      expect(h.app.loggedIn, isFalse);
      await expectLater(h.app.login('ali@x.co', 'Passw0rd1'), throwsA(isA<ApiException>()));
    });

    test('çıkışta cihazdaki yüklenmemiş fiş diskte kalır, aynı hesapla girişte geri gelir; başka hesap görmez', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      await h.app.saveDraft(_draft('Bekleyen'));
      await h.app.logout();
      h.backend.offline = false;

      await h.signIn('veli@x.co');
      expect(h.app.expenses, isEmpty);
      expect(h.app.pendingCount, 0, reason: 'Ali\'nin kuyruğu Veli\'nin hesabına yüklenmemeli');
      expect(h.backend.expensesOf('veli@x.co'), isEmpty);
      await h.app.logout();

      await h.signIn('ali@x.co');
      await _until(() => h.app.pendingCount == 0, reason: 'Ali girince kuyruk kendi hesabına yüklenir');
      expect(h.backend.expensesOf('ali@x.co').map((e) => e['merchant']), ['Bekleyen']);
      expect(h.backend.expensesOf('veli@x.co'), isEmpty);
    });
  });

  group('bulut senkronu AÇIK: çevrimdışı kuyruk', () {
    test('ağ yokken fiş + fotoğraf kaybolmaz, cihaz kuyruğuna alınır', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      h.backend.log.clear();

      final res = await h.app.saveDraft(_draft('BIM', images: [_img()]));
      expect(res.queued, isTrue);
      expect(res.imagesOk, isTrue);
      expect(h.app.pendingCount, 1);
      final e = h.app.expenses.single;
      expect(e.syncState, SyncState.pending);
      expect(e.id, lessThan(0), reason: 'yerel kimlik negatif');
      expect(e.localImages, hasLength(1));
      expect(h.local.images, hasLength(1), reason: 'fotoğraf cihaza yazıldı');
      expect(h.backend.expensesOf('ali@x.co'), isEmpty);
    });

    test('bağlantı gelince (connectivity) otomatik yüklenir: fiş ve fotoğraf buluta gider, yerelden silinir', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      await h.app.saveDraft(_draft('BIM', images: [_img(), _img()]));
      expect(h.app.pendingCount, 1);

      h.backend.offline = false;
      h.connectivity.emit(true);
      await _until(() => h.app.pendingCount == 0, reason: 'connectivity tetikli flush');

      final server = h.backend.expensesOf('ali@x.co');
      expect(server, hasLength(1));
      expect(h.backend.imageCount('ali@x.co', server.single['id'] as int), 2, reason: 'görseller dahil yüklendi');
      expect(h.local.images, isEmpty, reason: 'yerel görseller silindi');
      expect(h.app.expenses, hasLength(1), reason: 'listede tekrarlanmaz');
      expect(h.app.expenses.single.syncState, SyncState.synced);
    });

    test('uygulama ön plana gelince (resume) kuyruk boşalır', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      await h.app.saveDraft(_draft('BIM'));
      h.backend.offline = false;
      await h.app.onAppResumed();
      await _until(() => h.app.pendingCount == 0);
      expect(h.backend.expensesOf('ali@x.co'), hasLength(1));
    });

    test('herhangi bir ağ isteği başarılı olunca kuyruk otomatik boşalır', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      await h.app.saveDraft(_draft('BIM'));
      h.backend.offline = false;
      await h.app.refresh(); // başarılı GET -> onSuccess -> flush
      await _until(() => h.app.pendingCount == 0);
      expect(h.backend.expensesOf('ali@x.co'), hasLength(1));
    });

    test('flush ortasında ağ kesilirse kalanlar korunur; tekrar denemede mükerrer oluşmaz', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      await h.app.saveDraft(_draft('BIM', images: [_img()]));
      h.backend.offline = false;
      // Fiş toplu kayıtla oluşur, ardından bağlantı kopar (görsel yüklenemez).
      h.backend.afterRequest = (m, p) {
        if (p == '/expenses/bulk') h.backend.offline = true;
      };
      expect(await h.app.flushNow(force: true), FlushOutcome.offline);
      h.backend.afterRequest = null;
      final server = h.backend.expensesOf('ali@x.co');
      expect(server, hasLength(1));
      expect(h.backend.imageCount('ali@x.co', server.single['id'] as int), 0);
      expect(h.app.pendingCount, 1, reason: 'yerel kayıt (görsel kuyruğu) korunur');
      expect(h.local.images, hasLength(1));

      h.backend.offline = false;
      expect(await h.app.flushNow(force: true), FlushOutcome.done);
      expect(h.backend.expensesOf('ali@x.co'), hasLength(1), reason: 'mükerrer fiş yok');
      expect(h.backend.imageCount('ali@x.co', server.single['id'] as int), 1, reason: 'görsel bir kez yüklendi');
      expect(h.app.pendingCount, 0);
      expect(h.local.images, isEmpty);
      // Üçüncü kez çalıştırmak hiçbir şey yapmaz.
      expect(await h.app.flushNow(force: true), FlushOutcome.nothing);
    });

    test('doğrulama (400) hatası kuyruğa alınmaz, kullanıcıya iletilir', () async {
      await h.signIn('ali@x.co');
      await expectLater(
        h.app.saveDraft(_draft('BAD')),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 400)),
      );
      expect(h.app.pendingCount, 0);
      expect(h.app.expenses, isEmpty);
    });

    test('çevrimdışı oluşturulan profil bağlantı gelince bir kez oluşur; içindeki fişler de yüklenir', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      await h.app.createProfile('Ev');
      final home = h.app.activeProfile!;
      expect(home.state, SyncState.pending);
      await h.app.saveDraft(_draft('Migros'));
      expect(h.app.pendingCount, 2, reason: 'profil + fiş');

      await h.settle(50); // çevrimdışıyken başlayan arka plan flush'ı bitsin
      h.backend.offline = false;
      expect(await h.app.flushNow(force: true), FlushOutcome.done);
      expect(await h.app.flushNow(force: true), FlushOutcome.nothing);
      final ps = h.backend.user('ali@x.co').profiles;
      expect(ps.where((p) => p['client_uid'] == home.id), hasLength(1), reason: 'client_uid ile idempotent');
      final server = h.backend.expensesOf('ali@x.co');
      expect(server.single['profile_id'], ps.firstWhere((p) => p['client_uid'] == home.id)['id']);
      expect(h.app.profiles.where((p) => p.name == 'Ev'), hasLength(1));
    });
  });

  group('bulut senkronu KAPALI: gizlilik tercihi', () {
    test('internet olsa bile fiş, profil ve fotoğraf sunucuya yazılmaz; yalnızca cihazda kalır', () async {
      await h.signIn('ali@x.co');
      await h.app.setSyncEnabled(false);
      h.backend.log.clear();

      await h.app.createProfile('Gizli');
      final res = await h.app.saveDraft(_draft('Mahrem', images: [_img()]));
      expect(res.localOnly, isTrue);
      expect(h.app.expenses.single.syncState, SyncState.localOnly);
      expect(h.app.localOnlyCount, 2);

      // Tüm tetikleyiciler: flush, resume, connectivity, başarılı istek.
      expect(await h.app.flushNow(force: true), FlushOutcome.disabled);
      await h.app.onAppResumed();
      h.connectivity.emit(true);
      await h.app.refresh();
      await h.settle(50);

      expect(h.backend.writes, isEmpty, reason: 'sunucuya hiçbir yazma isteği gitmemeli: ${h.backend.writes}');
      expect(h.backend.expensesOf('ali@x.co'), isEmpty);
      expect(h.backend.user('ali@x.co').profiles.where((p) => p['name'] == 'Gizli'), isEmpty);
      expect(h.app.localOnlyCount, 2);
    });

    test('kapatınca bekleyen kuyruk yerele çekilir ve gönderilmez; açınca idempotent yüklenir', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      await h.app.saveDraft(_draft('Bekleyen'));
      expect(h.app.pendingCount, 1);

      h.backend.offline = false;
      await h.app.setSyncEnabled(false);
      expect(h.app.pendingCount, 0);
      expect(h.app.localOnlyCount, 1);
      h.connectivity.emit(true);
      await h.settle(50);
      expect(h.backend.expensesOf('ali@x.co'), isEmpty);

      await h.app.setSyncEnabled(true);
      await _until(() => h.app.localOnlyCount == 0 && h.app.pendingCount == 0);
      expect(h.backend.expensesOf('ali@x.co').map((e) => e['merchant']), ['Bekleyen']);
      // Aç/kapa/aç döngüsü mükerrer üretmez.
      await h.app.setSyncEnabled(false);
      await h.app.setSyncEnabled(true);
      await h.app.flushNow(force: true);
      expect(h.backend.expensesOf('ali@x.co'), hasLength(1));
    });

    test('kapalıyken cihazda oluşan profil, fiş ve fotoğraf açılınca tek seferde buluta aktarılır', () async {
      await h.signIn('ali@x.co');
      await h.app.setSyncEnabled(false);
      await h.app.createProfile('Yerel Profil');
      await h.app.saveDraft(_draft('Yerel Fis', images: [_img()]));
      expect(h.backend.expensesOf('ali@x.co'), isEmpty);

      await h.app.setSyncEnabled(true);
      await _until(() => h.app.localOnlyCount == 0 && h.app.pendingCount == 0, reason: 'yükleme');
      final server = h.backend.expensesOf('ali@x.co');
      expect(server, hasLength(1));
      expect(h.backend.imageCount('ali@x.co', server.single['id'] as int), 1);
      expect(h.backend.user('ali@x.co').profiles.map((p) => p['name']), contains('Yerel Profil'));
      expect(h.local.images, isEmpty);
    });

    test('kapalıyken bulut fişleri salt-okunur (düzenle/sil engellenir); yerel fişler serbest', () async {
      await h.signIn('ali@x.co');
      await h.app.saveDraft(_draft('Bulut Fis'));
      final cloud = h.app.expenses.single;
      await h.app.setSyncEnabled(false);
      h.backend.log.clear();

      await expectLater(
        h.app.deleteExpense(cloud.id),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', readOnlyCloudMessage)),
      );
      await expectLater(
        h.app.saveDraft(ReceiptDraft.from(cloud)..merchant = 'Degisti'),
        throwsA(isA<ApiException>()),
      );
      await expectLater(h.app.renameProfile(h.app.activeProfile!.id, 'Yeni Ad'), throwsA(isA<ApiException>()));
      expect(h.backend.writes, isEmpty);

      // Yerel fiş: düzenlenir ve silinir.
      await h.app.saveDraft(_draft('Yerel'));
      final local = h.app.expenses.firstWhere((e) => e.isLocal);
      final edited = ReceiptDraft.from(local)..merchant = 'Yerel 2';
      await h.app.saveDraft(edited);
      expect(h.app.expenses.firstWhere((e) => e.isLocal).merchant, 'Yerel 2');
      await h.app.deleteExpense(local.id);
      expect(h.app.expenses.where((e) => e.isLocal), isEmpty);
      expect(h.backend.writes, isEmpty);
    });

    test('senkron tercihi hesap bazlıdır ve yeniden açılışta korunur', () async {
      await h.signIn('ali@x.co');
      await h.app.setSyncEnabled(false);
      await h.app.logout();
      await h.signIn('veli@x.co');
      expect(h.app.syncEnabled, isTrue, reason: 'Veli\'nin varsayılanı açık');
      await h.app.logout();
      await h.signIn('ali@x.co');
      expect(h.app.syncEnabled, isFalse);
    });
  });

  group('kayıt / doğrulama akışı', () {
    test('kayıt kod gönderir; doğrulanmadan giriş yapılamaz; kodla doğrulayınca oturum açılır', () async {
      final cooldown = await h.app.register('yeni@x.co', 'Passw0rd1', name: 'Yeni');
      expect(cooldown, 60);
      expect(h.app.loggedIn, isFalse);
      await expectLater(
        h.app.login('yeni@x.co', 'Passw0rd1'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'email_not_verified')),
      );
      await expectLater(h.app.verifyEmail('yeni@x.co', '000000'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_code')));
      expect(h.app.loggedIn, isFalse);
      await h.app.verifyEmail('yeni@x.co', h.backend.lastCode);
      expect(h.app.loggedIn, isTrue);
      expect(h.app.profiles.map((p) => p.name), ['Kişisel']);
    });
  });
}

void _avatarTests() {
  late Harness h;
  setUp(() => h = Harness());

  group('profil avatarı', () {
    test('senkron açık + çevrimiçi: sunucuya yüklenir, sürüm profile yazılır, yerel dosya tutulmaz', () async {
      await h.signIn('ali@x.co');
      final id = h.app.activeProfile!.id;
      expect(h.app.activeProfile!.hasAvatar, isFalse);

      await h.app.setProfileAvatar(id, _img());
      final p = h.app.activeProfile!;
      expect(h.backend.avatarUploads, 1);
      expect(p.avatarVersion, 1);
      expect(p.localAvatarPath, isNull);
      expect(p.hasAvatar, isTrue);
      expect(h.local.images, isEmpty);

      // Sunucudan yeniden yüklemede de görünür kalır.
      await h.app.refresh();
      expect(h.app.activeProfile!.avatarVersion, 1);
    });

    test('senkron kapalı: yalnızca cihazda tutulur, sunucuya hiçbir şey gitmez; açınca yüklenir', () async {
      await h.signIn('ali@x.co');
      await h.app.setSyncEnabled(false);
      final id = h.app.activeProfile!.id;

      await h.app.setProfileAvatar(id, _img());
      var p = h.app.activeProfile!;
      expect(h.backend.avatarUploads, 0);
      expect(p.localAvatarPath, isNotNull);
      expect(p.hasAvatar, isTrue);
      expect(await h.app.readLocalImage(p.localAvatarPath!), _img());

      await h.app.refresh();
      expect(h.app.activeProfile!.localAvatarPath, isNotNull, reason: 'bulut yenilemesi yerel avatarı ezmez');

      await h.app.setSyncEnabled(true);
      await _until(() => h.backend.avatarUploads == 1, reason: 'bekleyen avatar yüklenmeli');
      await _until(() => h.app.activeProfile!.localAvatarPath == null);
      expect(h.app.activeProfile!.avatarVersion, 1);
      expect(h.local.images, isEmpty, reason: 'yüklenen avatarın yerel dosyası silinir');
    });

    test('çevrimdışı: cihazda bekler, bağlantı gelince otomatik yüklenir', () async {
      await h.signIn('ali@x.co');
      final id = h.app.activeProfile!.id;
      h.backend.offline = true;
      await h.app.setProfileAvatar(id, _img());
      expect(h.app.activeProfile!.localAvatarPath, isNotNull);
      expect(h.backend.avatarUploads, 0);

      h.backend.offline = false;
      await h.app.flushNow(force: true);
      await _until(() => h.backend.avatarUploads == 1);
      expect(h.app.activeProfile!.localAvatarPath, isNull);
      expect(h.app.activeProfile!.avatarVersion, 1);
    });

    test('kaldır: sunucu ve cihaz avatarı silinir; sync kapalıyken bulut avatarı salt okunur', () async {
      await h.signIn('ali@x.co');
      final id = h.app.activeProfile!.id;
      await h.app.setProfileAvatar(id, _img());
      await h.app.setSyncEnabled(false);
      await expectLater(h.app.removeProfileAvatar(id), throwsA(isA<ApiException>()));
      expect(h.app.activeProfile!.avatarVersion, 1);

      await h.app.setSyncEnabled(true);
      await h.app.removeProfileAvatar(id);
      expect(h.app.activeProfile!.hasAvatar, isFalse);
      expect(h.app.activeProfile!.avatarVersion, 0);
    });

    test('profil silinince yerel avatar dosyası da silinir; çıkışta başka hesaba sızmaz', () async {
      await h.signIn('ali@x.co');
      await h.app.setSyncEnabled(false);
      await h.app.createProfile('Ev');
      final home = h.app.activeProfile!;
      await h.app.setProfileAvatar(home.id, _img());
      expect(h.local.images, isNotEmpty);
      await h.app.deleteProfile(home.id);
      expect(h.local.images, isEmpty);

      await h.app.logout();
      await h.signIn('veli@x.co');
      expect(h.app.profiles.any((p) => p.hasAvatar), isFalse);
    });

    test('Profile JSON turu: avatar alanları yerel kayıtta korunur', () {
      final p = Profile(id: 'u', name: 'A', serverId: 3, avatarVersion: 4, localAvatarPath: 'x/y.jpg');
      final back = Profile.fromLocalJson(p.toLocalJson());
      expect(back.avatarVersion, 4);
      expect(back.localAvatarPath, 'x/y.jpg');
      expect(Profile.fromServerJson({'id': 1, 'name': 'B', 'client_uid': 'c', 'avatar_version': 2}).avatarVersion, 2);
      expect(Profile.fromServerJson({'id': 1, 'name': 'B', 'client_uid': 'c'}).avatarVersion, 0);
    });
  });
}
