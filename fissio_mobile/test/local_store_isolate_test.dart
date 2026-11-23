import 'dart:io';

import 'package:fissio_mobile/data/local_store.dart';
import 'package:fissio_mobile/models.dart';
import 'package:flutter_test/flutter_test.dart';

Expense _e(int i) => Expense(
  id: i,
  merchant: 'Market $i',
  amount: 10.0 + i,
  date: DateTime(2026, 1, 1).add(Duration(days: i % 300)),
  categoryId: 1 + i % 5,
  categoryName: 'Gıda',
  note: 'not $i ' * 3,
  items: [ExpenseItem('Süt', 5, categoryId: 1)],
  clientUid: 'uid-$i',
  profileUid: 'p1',
);

/// Büyük anlık görüntü isolate'ta kodlanıp çözülür; sonuç küçük (satır içi) yolla birebir aynı olmalı.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('fissio_store_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('küçük anlık görüntü: kaydet → yükle', () async {
    final store = FileLocalStore(baseDir: () async => dir);
    final snap = LocalSnapshot(cloudExpenses: [for (var i = 1; i <= 3; i++) _e(i)], cloudSyncedAt: '2026-01-01T00:00:00Z');
    await store.save(7, snap);
    final back = await store.load(7);
    expect(back.cloudExpenses.map((e) => e.clientUid), ['uid-1', 'uid-2', 'uid-3']);
    expect(back.cloudSyncedAt, '2026-01-01T00:00:00Z');
  });

  test('büyük anlık görüntü (isolate yolu): kayıpsız gidiş-dönüş', () async {
    final store = FileLocalStore(baseDir: () async => dir);
    final snap = LocalSnapshot(
      cloudExpenses: [for (var i = 1; i <= 600; i++) _e(i)],
      expenses: [_e(-1)],
      pendingDeletes: [5, 6],
      lastLocalId: -1,
    );
    await store.save(9, snap);
    final file = File('${dir.path}${Platform.pathSeparator}fissio${Platform.pathSeparator}user_9${Platform.pathSeparator}data.json');
    expect(file.lengthSync(), greaterThan(kIsolateJsonThreshold), reason: 'çözme tarafı da isolate eşiğini aşmalı');

    final back = await store.load(9);
    expect(back.cloudExpenses.length, 600);
    expect(back.cloudExpenses[599].merchant, 'Market 600');
    expect(back.cloudExpenses[599].items.single.name, 'Süt');
    expect(back.expenses.single.id, -1);
    expect(back.pendingDeletes, [5, 6]);
    expect(back.lastLocalId, -1);
  });
}
