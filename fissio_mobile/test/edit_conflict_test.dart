import 'dart:convert';
import 'dart:typed_data';

import 'package:fissio_mobile/data/local_store.dart';
import 'package:fissio_mobile/data/sync_service.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/data_management_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Çakışma farkındalıklı çevrimdışı düzenleme: bekleyen düzenleme, kuyruğa alındığı andaki sunucu sürümüyle
/// (`base_updated_at`) gönderilir; o arada başka cihaz fişi değiştirdiyse sessizce ezilmez.

const _email = 'ali@x.co';

ReceiptDraft _draft(String merchant, double amount) => ReceiptDraft(
  merchant: merchant,
  categoryId: 1,
  date: DateTime(2026, 5, 12),
  items: [ExpenseItem('kalem', amount, categoryId: 1)],
);

/// Çevrimiçi Migros (100) kaydeder, sonra çevrimdışıyken tutarı [mine] yapar (kuyrukta bekler).
Future<(Harness, int)> _offlineEdit({double mine = 200}) async {
  final h = Harness();
  await h.signIn(_email);
  await h.app.saveDraft(_draft('Migros', 100));
  final migros = h.app.expenses.single;
  h.backend.offline = true;
  final res = await h.app.saveDraft(ReceiptDraft.from(migros)..items = [ExpenseItem('kalem', mine, categoryId: 1)]);
  expect(res.queued, isTrue);
  return (h, migros.id);
}

double _serverAmount(Harness h) => (h.backend.expensesOf(_email).single['amount'] as num).toDouble();
List<Map<String, dynamic>> _puts(Harness h) => h.backend.putBodies;

void main() {
  test('eşzamanlı değişiklik yoksa çevrimdışı düzenleme tam bir kez uygulanır (base_updated_at ile)', () async {
    final (h, id) = await _offlineEdit();
    final base = (await h.local.load(h.app.user!.id)).pendingEdits.single.updatedAt;
    expect(base, isNotNull);
    h.backend.offline = false;
    expect(await h.app.flushNow(force: true), FlushOutcome.done);
    expect(_puts(h), hasLength(1));
    expect(_puts(h).single['base_updated_at'], base);
    expect(_serverAmount(h), 200);
    expect(h.app.conflictedEditCount, 0);
    expect(h.app.pendingCount, 0);
    expect(h.app.expenses.single.amount, 200);
    expect(h.app.expenses.single.syncState, SyncState.synced);
    // Tekrar boşaltma bir şey göndermez.
    expect(await h.app.flushNow(force: true), FlushOutcome.nothing);
    expect(_puts(h), hasLength(1));
    expect(h.app.expenses.single.id, id);
  });

  test('başka cihaz arada değiştirdiyse: 409, düzenleme korunur ve çakışma olarak işaretlenir, tekrar denenmez', () async {
    final (h, id) = await _offlineEdit();
    h.backend.serverEdit(_email, id, {'amount': 150.0});
    h.backend.offline = false;
    expect(await h.app.flushNow(force: true), FlushOutcome.partial);
    expect(_puts(h), hasLength(1));
    expect(_serverAmount(h), 150, reason: 'sunucudaki değişiklik sessizce ezilmez');

    expect(h.app.conflictedEditCount, 1);
    expect(h.app.pendingCount, 0, reason: 'çakışma "yüklenecek" sayılmaz');
    expect(h.app.failedSyncCount, 0, reason: '"kabul edilmedi" satırı çıkmaz');
    // Görünümde kullanıcının hali; önbellekte sunucudaki güncel hal.
    expect(h.app.expenses.single.amount, 200);
    final c = h.app.editConflicts.single;
    expect(c.mine.amount, 200);
    expect(c.server!.amount, 150);
    // Diske de yazıldı.
    final snap = await h.local.load(h.app.user!.id);
    expect(snap.pendingEdits.single.isEditConflict, isTrue);

    // Yeniden deneme fırtınası yok: sonraki boşaltmalar ve başarılı istekler PUT göndermez.
    expect(await h.app.flushNow(force: true), FlushOutcome.nothing);
    await h.app.refresh();
    await h.settle();
    expect(_puts(h), hasLength(1));
    expect(h.app.expenses.single.amount, 200, reason: 'yenileme sonrası da kullanıcının hali görünür');
  });

  test('düzenlemenin dayandığı sürüm kuyruğa alınırken sabitlenir: önce yenileme yapılsa da çakışma yakalanır', () async {
    final (h, id) = await _offlineEdit();
    h.backend.serverEdit(_email, id, {'amount': 150.0});
    h.backend.offline = false;
    // Yeni süreç: restoreSession önce refresh (önbelleğe 150 gelir), sonra flush.
    final reopened = Harness(backend: h.backend, prefs: h.prefs, local: h.local);
    expect(await reopened.app.restoreSession(), isTrue);
    await reopened.app.flushNow(force: true);
    await reopened.settle();
    expect(_serverAmount(h), 150);
    expect(reopened.app.conflictedEditCount, 1);
  });

  test('çakışma çözümü: "Benimkini koru" güncel sürümün üstüne yazar', () async {
    final (h, id) = await _offlineEdit();
    h.backend.serverEdit(_email, id, {'amount': 150.0});
    h.backend.offline = false;
    await h.app.flushNow(force: true);
    final serverStamp = h.backend.expensesOf(_email).single['updated_at'];

    await h.app.resolveEditConflict(id, keepMine: true);
    expect(_puts(h), hasLength(2));
    expect(_puts(h).last['base_updated_at'], serverStamp);
    expect(_serverAmount(h), 200);
    expect(h.app.conflictedEditCount, 0);
    expect(h.app.pendingCount, 0);
    expect((await h.local.load(h.app.user!.id)).pendingEdits, isEmpty);
    expect(h.app.expenses.single.amount, 200);
  });

  test('çakışma çözümü: "Sunucudakini al" düzenlemeyi (ve cihaz fotoğraflarını) atar', () async {
    final h = Harness();
    await h.signIn(_email);
    await h.app.saveDraft(_draft('Migros', 100));
    final migros = h.app.expenses.single;
    h.backend.offline = true;
    await h.app.saveDraft(
      ReceiptDraft.from(migros)
        ..items = [ExpenseItem('kalem', 200, categoryId: 1)]
        ..pendingImages = [Uint8List.fromList([9, 9])],
    );
    expect(h.local.images, hasLength(1));
    h.backend.serverEdit(_email, migros.id, {'amount': 150.0});
    h.backend.offline = false;
    await h.app.flushNow(force: true);
    expect(h.app.conflictedEditCount, 1);
    expect(h.backend.imageCount(_email, migros.id), 0, reason: 'çakışan düzenlemenin fotoğrafı da gönderilmedi');

    await h.app.resolveEditConflict(migros.id, keepMine: false);
    expect(_puts(h), hasLength(1));
    expect(_serverAmount(h), 150);
    expect(h.app.conflictedEditCount, 0);
    expect(h.app.expenses.single.amount, 150);
    expect(h.local.images, isEmpty);
    expect(await h.app.flushNow(force: true), FlushOutcome.nothing);
  });

  test('çevrimiçi (taze) düzenleme base_updated_at göndermez; eski sürümden kalan tabansız bekleyen düzenleme de gider', () async {
    final h = Harness();
    await h.signIn(_email);
    await h.app.saveDraft(_draft('Migros', 100));
    final migros = h.app.expenses.single;
    // Taze düzenleme: eski davranış (koşulsuz PUT).
    await h.app.saveDraft(ReceiptDraft.from(migros)..items = [ExpenseItem('kalem', 110, categoryId: 1)]);
    expect(_puts(h).single.containsKey('base_updated_at'), isFalse);
    expect(_serverAmount(h), 110);
    expect(h.app.expenses.single.updatedAt, h.backend.expensesOf(_email).single['updated_at']);

    // Uygulamanın eski sürümünde kuyruğa alınmış (updated_at'siz) düzenleme: tabansız gönderilir (geriye uyum).
    h.backend.offline = true;
    await h.app.saveDraft(ReceiptDraft.from(h.app.expenses.single)..items = [ExpenseItem('kalem', 130, categoryId: 1)]);
    final uid = h.app.user!.id;
    final raw = (await h.local.load(uid)).toJson();
    for (final e in raw['pending_edits'] as List) {
      (e as Map<String, dynamic>).remove('updated_at');
    }
    await h.local.save(uid, LocalSnapshot.fromJson(jsonDecode(jsonEncode(raw)) as Map<String, dynamic>));
    h.backend.serverEdit(_email, migros.id, {'note': 'başka cihaz'});
    h.backend.offline = false;
    final reopened = Harness(backend: h.backend, prefs: h.prefs, local: h.local);
    expect(await reopened.app.restoreSession(), isTrue);
    await reopened.app.flushNow(force: true);
    await reopened.settle();
    expect(_puts(h).last.containsKey('base_updated_at'), isFalse);
    expect(_serverAmount(h), 130);
    expect(reopened.app.conflictedEditCount, 0);
  });

  testWidgets('Veri Yönetimi: çakışma satırı ve çözüm penceresi', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Harness h;
    late int id;
    await tester.runAsync(() async {
      final r = await _offlineEdit();
      h = r.$1;
      id = r.$2;
      h.backend.serverEdit(_email, id, {'amount': 150.0});
      h.backend.offline = false;
      await h.app.flushNow(force: true);
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: DataManagementPage(app: h.app)));
    await tester.pump();
    expect(find.text('1 düzenleme sunucudakiyle çakıştı.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('conflict-resolve')));
    await tester.pumpAndSettle();
    expect(find.text('Düzenleme çakışması'), findsOneWidget);
    expect(find.textContaining(fmtMoney(200)), findsOneWidget);
    expect(find.textContaining(fmtMoney(150)), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('conflict-keep-mine')));
      for (var i = 0; i < 50 && h.app.conflictedEditCount > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await h.settle();
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conflict-status')), findsNothing);
    expect(_serverAmount(h), 200);
  });
}
