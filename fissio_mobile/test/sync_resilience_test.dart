import 'package:fissio_mobile/data/sync_service.dart';
import 'package:fissio_mobile/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Çevrimdışı kuyruğun dayanıklılığı: zehirli kayıt kuyruğu kilitlemez, düzenleme kaybolmaz, değişken fatura
/// "sabit"e dönmez, eşzamanlı refresh/flush ve hesap değişimi güvenli.

const _email = 'ali@x.co';
final _now = DateTime(2026, 5, 15, 12);

ReceiptDraft _draft(
  String merchant,
  double amount, {
  String? uid,
  int cat = 1,
  int recurringDay = 0,
  RecurringKind kind = RecurringKind.fixed,
  double estimate = 0,
}) => ReceiptDraft(
  clientUid: uid,
  merchant: merchant,
  categoryId: cat,
  date: DateTime(2026, 5, 12),
  items: [ExpenseItem('kalem', amount, categoryId: cat)],
  recurringDay: recurringDay,
  recurringKind: kind,
  recurringEstimate: estimate,
);

Future<Harness> _signedIn() async {
  final h = Harness(clock: () => _now);
  await h.signIn(_email);
  await h.settle();
  return h;
}

void main() {
  test('çevrimdışı kuyruktaki değişken fatura sunucuya "variable" + tahminle gider (sabit olmaz)', () async {
    final h = await _signedIn();
    h.backend.offline = true;
    await h.app.saveDraft(
      _draft('CK Elektrik', 520, uid: 'off-bill', cat: 11, recurringDay: 20, kind: RecurringKind.variable, estimate: 450),
    );
    final queued = h.app.expenses.firstWhere((e) => e.clientUid == 'off-bill');
    expect(queued.syncState, SyncState.pending);
    expect([queued.recurringKind, queued.recurringEstimate], [RecurringKind.variable, 450]);

    // Yeniden açılışta da (diskten) korunur.
    final reopened = Harness(backend: h.backend, prefs: h.prefs, local: h.local, clock: () => _now);
    expect(await reopened.app.restoreSession(), isTrue);
    final fromDisk = reopened.app.expenses.firstWhere((e) => e.clientUid == 'off-bill');
    expect([fromDisk.recurringKind, fromDisk.recurringEstimate], [RecurringKind.variable, 450]);

    h.backend.offline = false;
    await h.app.flushNow(force: true);
    final server = h.backend.expensesOf(_email).single;
    expect(server['recurring_kind'], 'variable');
    expect(server['recurring_estimate'], 450);
    expect(h.app.pendingCount, 0);
  });

  test('çevrimdışıyken düzenlenen sunucu fişi (PUT) de değişken türünü korur', () async {
    final h = await _signedIn();
    await h.app.saveDraft(_draft('Su', 200, uid: 'su-1', cat: 11, recurringDay: 10, kind: RecurringKind.variable, estimate: 250));
    await h.app.refresh();
    final cloud = h.app.expenses.firstWhere((e) => e.clientUid == 'su-1');

    h.backend.offline = true;
    final edit = ReceiptDraft.from(cloud)..items = [ExpenseItem('fatura', 260, categoryId: 11)];
    expect((await h.app.saveDraft(edit)).queued, isTrue);
    final pending = h.app.expenses.firstWhere((e) => e.clientUid == 'su-1');
    expect(pending.recurringKind, RecurringKind.variable);
    expect(pending.recurringEstimate, 250);

    h.backend.offline = false;
    await h.app.flushNow(force: true);
    final server = h.backend.expensesOf(_email).single;
    expect(server['recurring_kind'], 'variable');
    expect((server['amount'] as num).toDouble(), 260);
  });

  test('zehirli (sunucunun reddettiği) kayıt kuyruğu kilitlemez: diğer fişler ve bütçeler yine de gider', () async {
    final h = await _signedIn();
    h.backend.offline = true;
    await h.app.saveDraft(_draft('Migros', 100, uid: 'ok-1'));
    await h.app.saveDraft(_draft('BAD', 50, uid: 'poison'));
    await h.app.saveDraft(_draft('Şok', 120, uid: 'ok-2'));
    await h.app.setBudget(1, 3000); // sonraki adım (bütçe) de bloklanmamalı

    h.backend.offline = false;
    final out = await h.app.flushNow(force: true);
    expect(out, FlushOutcome.partial);

    final server = h.backend.expensesOf(_email).map((e) => e['client_uid']).toSet();
    expect(server, {'ok-1', 'ok-2'});
    expect(h.backend.user(_email).budgets, hasLength(1), reason: 'bütçe adımı zehirli kayıttan etkilenmedi');

    final stuck = h.app.expenses.where((e) => e.syncState == SyncState.pending).toList();
    expect(stuck.map((e) => e.clientUid), ['poison']);
    expect(stuck.single.syncFailures, 1);
    expect(stuck.single.syncError, isNotEmpty);
    expect(h.app.failedSyncCount, 1);

    // Sayaç diske yazılır (yeniden açılışta kaybolmaz).
    final snap = await h.local.load(h.app.user!.id);
    expect(snap.expenses.single.syncFailures, 1);
  });

  test('sunucu çoklu partiyi 500 ile reddederse kayıtlar tek tek denenir; yalnızca bozuk olan kalır', () async {
    final h = await _signedIn();
    h.backend.offline = true;
    await h.app.saveDraft(_draft('Migros', 100, uid: 'ok-1'));
    await h.app.saveDraft(_draft('BAD', 50, uid: 'poison'));
    await h.app.saveDraft(_draft('Şok', 120, uid: 'ok-2'));

    h.backend.offline = false;
    h.backend.failMultiBulk = true;
    final out = await h.app.flushNow(force: true);
    expect(out, FlushOutcome.partial);
    expect(h.backend.expensesOf(_email).map((e) => e['client_uid']).toSet(), {'ok-1', 'ok-2'});
    expect(h.app.expenses.where((e) => e.syncState == SyncState.pending).map((e) => e.clientUid), ['poison']);
  });

  test('geri çekilme üsteldir: tekrar eden hatada deneme aralığı büyür, zorla tetiklenince yine de denenir', () async {
    var now = _now;
    final h = Harness(clock: () => now);
    await h.signIn(_email);
    await h.settle();
    h.backend.offline = true;
    await h.app.saveDraft(_draft('BAD', 50, uid: 'poison'));
    h.backend.offline = false;

    expect(await h.app.flushNow(force: true), FlushOutcome.partial); // 1. başarısızlık → 60 sn
    expect(await h.app.flushNow(), FlushOutcome.busy, reason: 'bekleme süresi dolmadı');
    now = now.add(const Duration(seconds: 61));
    expect(await h.app.flushNow(), FlushOutcome.partial); // 2. başarısızlık → 120 sn
    now = now.add(const Duration(seconds: 61));
    expect(await h.app.flushNow(), FlushOutcome.busy, reason: '120 sn dolmadı');
    now = now.add(const Duration(seconds: 61));
    expect(await h.app.flushNow(), FlushOutcome.partial);
    expect(h.app.expenses.firstWhere((e) => e.clientUid == 'poison').syncFailures, 3);
  });

  test('yanıtı kaybolan bulk sonrası yerel düzenleme: "skipped" fişte düzenleme sunucuya yazılır, kaybolmaz', () async {
    final h = await _signedIn();
    h.backend.offline = true;
    await h.app.saveDraft(_draft('Migros', 100, uid: 'lost-1'));
    final queued = h.app.expenses.firstWhere((e) => e.clientUid == 'lost-1');

    // Aynı fiş başka bir kanaldan (yanıtı kaybolan önceki deneme) sunucuda zaten oluşmuş.
    h.backend.offline = false; // sunucu ayakta; h henüz flush etmedi (kuyruk bizde kalır)
    final other = Harness(backend: h.backend, clock: () => _now);
    await other.signIn(_email);
    final serverProfile = h.app.activeProfile!.serverId!;
    await other.app.api.bulkExpenses([SyncService.bulkBody(queued, 11)], profileId: serverProfile);
    expect(h.backend.expensesOf(_email).single['amount'], 100);

    // Kullanıcı bu arada yerel kopyayı düzenledi (100 → 150).
    final edit = ReceiptDraft.from(queued)..items = [ExpenseItem('kalem', 150, categoryId: 1)];
    await h.app.saveDraft(edit);
    expect(h.app.expenses.firstWhere((e) => e.clientUid == 'lost-1').amount, 150);

    await h.app.flushNow(force: true);
    final server = h.backend.expensesOf(_email).single;
    expect((server['amount'] as num).toDouble(), 150, reason: 'düzenleme "skipped" yüzünden kaybolmamalı');
    expect(h.app.pendingCount, 0);
  });

  test('değişmemiş "skipped" fiş için gereksiz PUT atılmaz', () async {
    final h = await _signedIn();
    h.backend.offline = true;
    await h.app.saveDraft(_draft('Migros', 100, uid: 'same-1'));
    final queued = h.app.expenses.firstWhere((e) => e.clientUid == 'same-1');
    h.backend.offline = false;
    final other = Harness(backend: h.backend, clock: () => _now);
    await other.signIn(_email);
    await other.app.api.bulkExpenses([SyncService.bulkBody(queued, 11)], profileId: h.app.activeProfile!.serverId!);

    await h.app.flushNow(force: true);
    expect(h.backend.writes.where((w) => w.startsWith('PUT /expenses/')), isEmpty);
    expect(h.app.pendingCount, 0);
  });

  test('sameContent: kullanıcının düzenleyebildiği her alan karşılaştırılır', () {
    Expense mk({double amount = 100, String note = '', int cat = 1, RecurringKind kind = RecurringKind.fixed}) => Expense(
      id: 1,
      merchant: 'Migros',
      amount: amount,
      date: DateTime(2026, 5, 12),
      categoryId: cat,
      categoryName: 'x',
      note: note,
      items: [ExpenseItem('kalem', amount, categoryId: 1)],
      recurringDay: 10,
      recurringKind: kind,
    );
    expect(SyncService.sameContent(mk(), mk(), 11), isTrue);
    expect(SyncService.sameContent(mk(), mk(amount: 101), 11), isFalse);
    expect(SyncService.sameContent(mk(), mk(note: 'x'), 11), isFalse);
    expect(SyncService.sameContent(mk(), mk(cat: 2), 11), isFalse);
    expect(SyncService.sameContent(mk(), mk(kind: RecurringKind.variable), 11), isFalse);
    // Kategori atanmamış (0) yerel fiş, sunucuda "Diğer" olarak saklanır.
    expect(SyncService.sameContent(mk(cat: 0), mk(cat: 11), 11), isTrue);
  });

  test('refresh ile flush eşzamanlı çalışmaz: kuyruk boşalırken gelen bayat sunucu listesi yerel profili ezmez', () async {
    final h = await _signedIn();
    // Çevrimdışı yeni profil + o profilde fiş.
    h.backend.offline = true;
    await h.app.createProfile('Ev');
    final home = h.app.profiles.firstWhere((p) => p.name == 'Ev');
    await h.app.selectProfile(home);
    await h.app.saveDraft(_draft('Migros', 100, uid: 'home-1'));

    h.backend.offline = false;
    // İkisi birden tetiklenir (bağlantı gelince uygulamada olan şey): sıraya girmeli.
    await Future.wait([h.app.refresh(), h.app.flushNow(force: true), h.app.refresh()]);
    await h.settle();

    expect(h.app.pendingCount, 0);
    final ev = h.app.profiles.where((p) => p.name == 'Ev').toList();
    expect(ev, hasLength(1), reason: 'profil çift/kayıp olmamalı');
    expect(ev.single.serverId, isNotNull);
    final server = h.backend.expensesOf(_email);
    expect(server.map((e) => e['client_uid']), ['home-1']);
    expect(h.app.expenses.map((e) => e.clientUid), ['home-1']);
    expect(h.app.activeProfile!.name, 'Ev');
  });

  test('kategori önbelleği boşken kuyruğa alınan kategorisiz fiş "Diğer" ile yüklenir (category_id null gitmez)', () async {
    final h = await _signedIn();
    h.backend.offline = true;
    await h.app.saveDraft(_draft('Bilinmeyen', 30, uid: 'nocat-1', cat: 0));
    // Çevrimdışı ilk kullanım simülasyonu: kategori önbelleği boş.
    h.app.categories = [];
    final snap = await h.local.load(1);
    snap.categories = [];
    await h.local.save(1, snap);
    h.backend.offline = false;
    final reopened = Harness(backend: h.backend, prefs: h.prefs, local: h.local, clock: () => _now);
    expect(await reopened.app.restoreSession(), isTrue);
    reopened.app.categories = [];
    await reopened.app.flushNow(force: true);
    final server = h.backend.expensesOf(_email).single;
    expect(server['category_id'], 11, reason: 'Diğer');
    expect(h.backend.writes.where((w) => w.startsWith('POST /expenses/bulk')), isNotEmpty);
  });

  test('senkron sonrası fiş, refresh başarısız olsa bile listede kalır (sunucu kopyası önbelleğe hemen eklenir)', () async {
    final h = await _signedIn();
    h.backend.offline = true;
    await h.app.saveDraft(_draft('Migros', 100, uid: 'keep-1'));
    h.backend.offline = false;
    h.backend.failPaths.add('GET /expenses'); // refresh başarısız
    await h.app.flushNow(force: true);
    await h.settle();
    final e = h.app.expenses.where((x) => x.clientUid == 'keep-1').toList();
    expect(e, hasLength(1), reason: 'kuyruktan çıkan fiş kaybolmamalı');
    expect(e.single.id, greaterThan(0), reason: 'sunucu kimliğiyle (detay sayfası bulabilsin)');
    expect(e.single.syncState, SyncState.synced);
  });

  test('flush sürerken hesap değişirse kalan çağrılar yeni hesabın token\'ıyla gönderilmez', () async {
    final h = await _signedIn();
    h.backend.offline = true;
    await h.app.saveDraft(_draft('Migros', 100, uid: 'a-1'));
    await h.app.saveDraft(_draft('Şok', 120, uid: 'a-2'));
    h.backend.offline = false;

    // İlk istek (profil/kategori) döndüğünde kullanıcı çıkış yapar.
    var logoutTriggered = false;
    h.backend.afterRequest = (method, path) {
      if (!logoutTriggered && method == 'POST' && path == '/expenses/bulk') {
        logoutTriggered = true;
        h.app.logout();
      }
    };
    await h.app.flushNow(force: true);
    await h.settle();
    h.backend.afterRequest = null;

    // Bulk isteğinden sonra hiçbir sunucu yazması (fiş/profil/fotoğraf/bütçe) yapılmaz; bulk tam bir kez gitti.
    final log = h.backend.log;
    final bulkAt = log.indexWhere((l) => l.method == 'POST' && l.path == '/expenses/bulk');
    expect(bulkAt, isNonNegative, reason: 'flush bulk isteğine ulaşmalıydı');
    expect(log.where((l) => l.method == 'POST' && l.path == '/expenses/bulk'), hasLength(1));
    final lateWrites = [
      for (final l in log.skip(bulkAt + 1))
        if (l.method != 'GET' && !l.path.startsWith('/auth/')) '${l.method} ${l.path}',
    ];
    expect(lateWrites, isEmpty, reason: 'çıkıştan sonra yazma olmamalı: $lateWrites');
    // Hiçbir fiş kaybolmaz: her biri ya sunucuda (bulk işlendi) ya da diskteki kuyrukta durur.
    final snap = await h.local.load(1);
    final held = {
      ...snap.expenses.map((e) => e.clientUid),
      ...h.backend.expensesOf(_email).map((e) => e['client_uid']),
    };
    expect(held, containsAll(['a-1', 'a-2']));
  });
}
