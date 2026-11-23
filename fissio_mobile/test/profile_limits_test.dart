import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Profil kuralları (sunucu `profiles.go` ile aynı): hesap başına en fazla [kMaxProfiles] profil ve aynı adda ikinci profil
/// yok (Türkçe katlamalı, büyük/küçük harf ve boşluk duyarsız). Yerelde de uygulanır: bekleyen/yerel profil sonradan
/// sunucuda 409 alıp kuyrukta takılmasın.

Matcher _code(String code) => isA<ApiException>().having((e) => e.code, 'code', code);

void main() {
  test('profileNameKey Go profileNameKey ile aynı', () {
    expect(profileNameKey('İstanbul'), 'istanbul');
    expect(profileNameKey('  ISTANBUL  '), 'istanbul');
    expect(profileNameKey('Ev   İş'), 'ev is');
    expect(profileNameKey('Kişisel'), 'kisisel');
  });

  test('8 profil sınırı: bekleyen (çevrimdışı) profiller de sayılır; mesaj Türkçe', () async {
    final h = Harness();
    await h.signIn('lim@x.co');
    expect(h.app.profiles.length, 1);
    for (var i = 2; i <= 6; i++) {
      await h.app.createProfile('Profil $i');
    }
    h.backend.offline = true;
    await h.app.createProfile('Çevrimdışı 1');
    await h.app.createProfile('Çevrimdışı 2');
    h.backend.offline = false;
    expect(h.app.profiles.length, kMaxProfiles);
    expect(h.app.canAddProfile, isFalse);
    await expectLater(h.app.createProfile('Dokuzuncu'), throwsA(_code('profile_limit')));
    try {
      await h.app.createProfile('Dokuzuncu');
    } on ApiException catch (e) {
      expect(e.message, 'Maksimum 8 profil oluşturabilirsiniz.');
    }
    expect(h.app.profiles.length, kMaxProfiles);
  });

  test('sunucu 409 profile_limit (başka cihazda dolduruldu) Türkçe mesajla yukarı çıkar', () async {
    final h = Harness();
    await h.signIn('srv@x.co');
    final u = h.backend.user('srv@x.co');
    for (var i = 0; i < 7; i++) {
      u.profiles.add({'id': 9000 + i, 'name': 'Diğer cihaz $i', 'client_uid': 'srv-other-$i'});
    }
    await expectLater(h.app.createProfile('Yeni'), throwsA(_code('profile_limit')));
    try {
      await h.app.createProfile('Yeni');
    } on ApiException catch (e) {
      expect(e.message, kProfileLimitMessage);
    }
  });

  test('aynı ad: oluşturma ve yeniden adlandırma engellenir; profilin kendi adını harf değiştirmesi serbest', () async {
    final h = Harness();
    await h.signIn('ad@x.co');
    final personal = h.app.activeProfile!;
    expect(personal.name, 'Kişisel');
    await expectLater(h.app.createProfile('  KİŞİSEL '), throwsA(_code('duplicate_profile_name')));
    await expectLater(h.app.createProfile('kisisel'), throwsA(_code('duplicate_profile_name')));
    await h.app.createProfile('İş');
    final work = h.app.activeProfile!;
    await expectLater(h.app.renameProfile(work.id, 'kişisel'), throwsA(_code('duplicate_profile_name')));
    await h.app.renameProfile(work.id, 'İŞ');
    expect(h.app.profiles.firstWhere((p) => p.id == work.id).name, 'İŞ');

    // Sunucuda (başka cihazdan) eklenmiş, bu cihazın henüz görmediği ad: sunucu 409 → kullanıcı dostu mesaj.
    h.backend.user('ad@x.co').profiles.add({'id': 777, 'name': 'Ortak', 'client_uid': 'srv-ortak'});
    try {
      await h.app.createProfile('ortak');
      fail('409 beklenirdi');
    } on ApiException catch (e) {
      expect(e.code, 'duplicate_profile_name');
      expect(e.message, kDuplicateProfileNameMessage);
    }
  });
}
