import 'dart:typed_data';

import 'package:fissio_mobile/app_state.dart';
import 'package:fissio_mobile/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Artımlı (delta) yenileme: önbellek + `cloudSyncedAt` varken yalnızca `GET /expenses?since=` + `GET /expenses/ids`
/// çekilir; ilk açılışta ve artımlı yol başarısız olunca tam liste.

const _email = 'ali@x.co';

ReceiptDraft _draft(String merchant, double amount) => ReceiptDraft(
  merchant: merchant,
  categoryId: 1,
  date: DateTime(2026, 5, 12),
  items: [ExpenseItem('kalem', amount, categoryId: 1)],
);

Future<Harness> _seed() async {
  final h = Harness();
  await h.signIn(_email);
  for (final (m, a) in [('Migros', 100.0), ('Şok', 50.0), ('BIM', 30.0), ('A101', 20.0)]) {
    await h.app.saveDraft(_draft(m, a));
  }
  await h.app.refresh();
  return h;
}

int _serverId(Harness h, String merchant) =>
    h.backend.expensesOf(_email).firstWhere((e) => e['merchant'] == merchant)['id'] as int;

/// [from] indeksinden sonraki `GET /expenses*` istekleri.
List<Uri> _expenseReads(Harness h, int from) =>
    [for (final u in h.backend.requests.skip(from)) if (u.path.startsWith('/expenses') && !u.path.contains('/images')) u];

void main() {
  test('ilk açılış (önbellek yok) tam listeyi çeker ve en yeni updated_at\'i saklar', () async {
    final h = Harness();
    h.backend.addUser(_email, 'Passw0rd1');
    await h.signIn(_email);
    expect(h.backend.fullListCalls, 1);
    expect(h.backend.sinceCalls, 0);
    expect(h.backend.idsCalls, 0);
    // Fiş yokken updated_at de yok: sonraki yenileme de tam liste (boş, ucuz).
    expect((await h.local.load(h.app.user!.id)).cloudSyncedAt, isNull);

    final h2 = await _seed();
    final snap = await h2.local.load(h2.app.user!.id);
    final newest = h2.backend.expensesOf(_email).map((e) => e['updated_at'] as String).reduce(
      (a, b) => DateTime.parse(a).isAfter(DateTime.parse(b)) ? a : b,
    );
    expect(snap.cloudSyncedAt, newest, reason: 'ham metin aynen');
    expect(snap.cloudExpenses.every((e) => e.updatedAt != null), isTrue);
  });

  test('sıcak yenileme artımlıdır: yalnızca since + ids; başka cihazın düzenlemesi ve silmesi gelir', () async {
    final h = await _seed();
    final syncedAt = (await h.local.load(h.app.user!.id)).cloudSyncedAt!;
    h.backend.serverEdit(_email, _serverId(h, 'Migros'), {'amount': 120.0, 'merchant': 'Migros Jet'});
    h.backend.serverDelete(_email, _serverId(h, 'Şok'));

    final from = h.backend.requests.length;
    await h.app.refresh();
    final reads = _expenseReads(h, from);
    expect(reads.map((u) => u.path), ['/expenses', '/expenses/ids'], reason: 'önce değişenler, sonra kimlikler');
    expect(reads.first.queryParameters['since'], isNotNull, reason: 'tam liste çekilmez');
    final since = DateTime.parse(reads.first.queryParameters['since']!);
    expect(since, DateTime.parse(syncedAt).subtract(AppState.cloudDeltaOverlap));
    // Seçici: eski ve dokunulmamış fiş (BIM) sunucudan yeniden gelmedi, önbellekten kaldı.
    final bim = h.backend.expensesOf(_email).firstWhere((e) => e['merchant'] == 'BIM');
    expect(DateTime.parse(bim['updated_at'] as String).isAfter(since), isFalse);

    final byName = {for (final e in h.app.expenses) e.merchant: e};
    expect(byName.keys.toSet(), {'Migros Jet', 'BIM', 'A101'});
    expect(byName['Migros Jet']!.amount, 120);
    expect(h.app.offline, isFalse);
    expect(h.app.error, isNull);
    final snap = await h.local.load(h.app.user!.id);
    expect(DateTime.parse(snap.cloudSyncedAt!).isAfter(DateTime.parse(syncedAt)), isTrue);
    expect(snap.cloudExpenses.map((e) => e.merchant).toSet(), {'Migros Jet', 'BIM', 'A101'});
  });

  test('uygulama yeniden açılınca (diskteki önbellek) yenileme artımlı; profil eşlemesi korunur', () async {
    final h = await _seed();
    h.backend.serverEdit(_email, _serverId(h, 'BIM'), {'amount': 33.0});
    final reopened = Harness(backend: h.backend, prefs: h.prefs, local: h.local);
    final full = h.backend.fullListCalls;
    expect(await reopened.app.restoreSession(), isTrue);
    await reopened.app.restoreSettled; // yenileme arka planda sürer
    expect(h.backend.fullListCalls, full, reason: 'yeniden açılışta tüm geçmiş indirilmez');
    expect(reopened.app.expenses.map((e) => e.merchant).toSet(), {'Migros', 'Şok', 'BIM', 'A101'});
    expect(reopened.app.expenses.firstWhere((e) => e.merchant == 'BIM').amount, 33);
    expect(reopened.app.expenses.every((e) => e.profileUid == reopened.app.activeProfileId), isTrue);
  });

  test('artımlı yol başarısız olursa (ör. /expenses/ids 500) tam listeye düşer', () async {
    final h = await _seed();
    h.backend.serverDelete(_email, _serverId(h, 'A101'));
    h.backend.failPaths.add('GET /expenses/ids');
    final full = h.backend.fullListCalls;
    await h.app.refresh();
    expect(h.backend.fullListCalls, full + 1);
    expect(h.app.error, isNull);
    expect(h.app.expenses.map((e) => e.merchant).toSet(), {'Migros', 'Şok', 'BIM'});
  });

  test('bağlantı yokken artımlı yenileme çevrimdışı moda geçer, önbellek korunur', () async {
    final h = await _seed();
    h.backend.offline = true;
    await h.app.refresh();
    expect(h.app.offline, isTrue);
    expect(h.app.error, isNull);
    expect(h.app.expenses, hasLength(4));
  });

  test('çıkışta önbellekle birlikte cloudSyncedAt da silinir; tekrar girişte tam liste', () async {
    final h = await _seed();
    final uid = h.app.user!.id;
    await h.app.logout();
    final snap = await h.local.load(uid);
    expect(snap.cloudExpenses, isEmpty);
    expect(snap.cloudSyncedAt, isNull);
    final full = h.backend.fullListCalls;
    await h.signIn(_email);
    expect(h.backend.fullListCalls, full + 1);
    expect(h.app.expenses, hasLength(4));
  });

  test('fotoğraf eklemek updated_at\'i değiştirmez ama fişin görsel kimlikleri yine güncellenir', () async {
    final h = await _seed();
    final bim = h.app.expenses.firstWhere((e) => e.merchant == 'BIM');
    await h.app.addImages(bim, [Uint8List.fromList([1, 2, 3])]);
    final after = h.app.expenses.firstWhere((e) => e.merchant == 'BIM');
    expect(after.imageIds, hasLength(1));
    expect(after.updatedAt, bim.updatedAt);
    await h.app.removeCloudImage(bim.id, after.imageIds.single);
    expect(h.app.expenses.firstWhere((e) => e.merchant == 'BIM').imageIds, isEmpty);
  });
}
