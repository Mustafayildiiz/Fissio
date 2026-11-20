import 'package:fissio_mobile/budgets.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/budget_widgets.dart';
import 'package:fissio_mobile/pages/sync_status_badge.dart';
import 'package:fissio_mobile/stats.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Tam çevrimdışı-öncelikli mimari: internet varken çekilen veriler kullanıcı bazlı yerel depoya yazılır; internet
/// yokken uygulama YENİ bir süreç gibi (yeni AppState, aynı disk) açıldığında hepsi görünür ve çalışır.

const _email = 'ali@x.co';
final _now = DateTime(2026, 5, 15, 12);

ReceiptDraft _draft(
  String merchant,
  double amount, {
  int cat = 1,
  DateTime? date,
  int recurringDay = 0,
  RecurringKind kind = RecurringKind.fixed,
  String? uid,
}) => ReceiptDraft(
  clientUid: uid,
  merchant: merchant,
  categoryId: cat,
  date: date ?? DateTime(2026, 5, 12),
  items: [ExpenseItem('kalem', amount, categoryId: cat)],
  recurringDay: recurringDay,
  recurringKind: kind,
);

/// İnternet varken hesabı doldurur: fişler, kategori + toplam bütçe, değişken fatura serisi.
Future<Harness> _seedOnline() async {
  final h = Harness(clock: () => _now);
  await h.signIn(_email);
  await h.app.saveDraft(_draft('Migros', 850));
  await h.app.saveDraft(_draft('Lokanta', 600, cat: 2));
  for (final (m, a) in [(2, 400.0), (3, 500.0), (4, 600.0)]) {
    await h.app.saveDraft(
      _draft('CK Elektrik', a, cat: 11, date: DateTime(2026, m, 20), recurringDay: 20, kind: RecurringKind.variable),
    );
  }
  await h.app.setBudget(1, 1000);
  await h.app.setBudget(kTotalBudgetCategoryId, 5000);
  await h.app.refresh();
  return h;
}

/// Aynı diskle (prefs + yerel depo) yeni bir uygulama süreci; sunucuya ulaşılamıyor.
Future<Harness> _reopenOffline(Harness h) async {
  final h2 = Harness(backend: h.backend, prefs: h.prefs, local: h.local, clock: () => _now);
  h.backend.offline = true;
  expect(await h2.app.restoreSession(), isTrue);
  return h2;
}

void main() {
  test('internet kesikken uygulama açılınca geçmiş fişler, profiller, bütçeler, rapor ve projeksiyon yerel önbellekten gelir', () async {
    final h = await _seedOnline();
    final online = h.app;
    final onlineIds = online.expenses.map((e) => e.id).toList();
    expect(online.expenses.length, 5);

    final h2 = await _reopenOffline(h);
    final app = h2.app;
    // Sunucu hata değil: sakin "çevrimdışı" durumu; veriler önbellekten.
    expect(app.offline, isTrue);
    expect(app.error, isNull);
    expect(app.profiles.map((p) => p.name), contains('Kişisel'));
    expect(app.categories, isNotEmpty);
    expect(app.expenses.map((e) => e.id).toList(), onlineIds, reason: 'aynı fişler, aynı sıra');
    expect(app.expenses.every((e) => e.syncState == SyncState.synced), isTrue);

    // Rapor özeti (Özet sayfasının kullandığı hesap) çevrimdışı da aynı.
    final s = computeHomeStats(app.expenses, HomePeriod.quarter, now: _now);
    expect(s.count, 5);
    expect(s.total, 850 + 600 + 400 + 500 + 600);
    expect(s.categories.isNotEmpty, isTrue);

    // Bütçeler: toplam limit önde, kategori limiti ardından; harcamalar önbellekteki fişlerden.
    final b = app.budgetProgress;
    expect(b.map((p) => p.budget.categoryId), [kTotalBudgetCategoryId, 1]);
    expect(b[0].spent, 1450, reason: 'Mayıs: Migros 850 + Lokanta 600');
    expect(b[0].level, BudgetLevel.ok);
    expect(b[1].spent, 850);
    expect(b[1].level, BudgetLevel.warning);

    // Sabit/değişken gider projeksiyonu: Elektrik tahmini = son 3 ayın ortalaması.
    final r = app.recurring;
    expect(r.items.single.expected, 500);
    expect(r.monthlyTotal, 500);
    expect(r.items.single.paidThisMonth, isFalse);

    // Bu diskten gelen veriyle ekranlar çizilir (tam işlevsel).
    expect(h.local.hasData(app.user!.id), isTrue);
    expect(h.backend.writes.where((w) => w.startsWith('POST /auth/login')).length, 1);
  });

  test('çevrimdışı eklenen/düzenlenen/silinen kayıtlar yerel görünümle birleşir, yeniden açılışta korunur ve bağlantı gelince buluta gider', () async {
    final h = await _seedOnline();
    final h2 = await _reopenOffline(h);
    final app = h2.app;

    final migros = app.expenses.firstWhere((e) => e.merchant == 'Migros');
    final lokanta = app.expenses.firstWhere((e) => e.merchant == 'Lokanta');

    // 1) çevrimdışı YENİ fiş
    await app.saveDraft(_draft('Şok', 120, uid: 'off-sok'));
    // 2) çevrimdışı DÜZENLEME (sunucudaki fiş): tutar 850 -> 900
    final edit = ReceiptDraft.from(migros)..items = [ExpenseItem('kalem', 900, categoryId: 1)];
    final res = await app.saveDraft(edit);
    expect(res.queued, isTrue, reason: 'hata değil, kuyruğa alındı');
    // 3) çevrimdışı SİLME
    await app.deleteExpense(lokanta.id);
    // 4) çevrimdışı bütçe değişikliği + silme
    await app.setBudget(1, 2000);
    await app.removeBudget(kTotalBudgetCategoryId);

    void expectMergedView(Harness x) {
      final byName = {for (final e in x.app.expenses) e.merchant: e};
      expect(byName.keys, containsAll(['Şok', 'Migros', 'CK Elektrik']));
      expect(byName.containsKey('Lokanta'), isFalse, reason: 'silinen fiş görünmez');
      expect(byName['Migros']!.amount, 900, reason: 'düzenleme yerel görünümde');
      expect(byName['Migros']!.syncState, SyncState.pending);
      expect(byName['Şok']!.syncState, SyncState.pending);
      expect(x.app.budgetProgress.map((p) => p.budget.categoryId), [1], reason: 'toplam limit silindi');
      expect(x.app.budgetProgress.single.budget.limit, 2000);
      expect(x.app.pendingCount, greaterThanOrEqualTo(5));
    }

    expectMergedView(h2);

    // Uygulama yine çevrimdışı yeniden açılır: bekleyen değişiklikler diskten gelir.
    final h3 = Harness(backend: h.backend, prefs: h.prefs, local: h.local, clock: () => _now);
    expect(await h3.app.restoreSession(), isTrue);
    expectMergedView(h3);

    // Bağlantı geldi: hepsi buluta gider, kuyruk boşalır.
    await h3.settle(); // açılışta başlayan (çevrimdışı) flush bitsin
    h.backend.offline = false;
    final out = await h3.app.flushNow(force: true);
    expect(out.name, anyOf('done', 'partial'));
    final server = {for (final e in h.backend.expensesOf(_email)) e['merchant'] as String: e};
    expect(server.keys, containsAll(['Şok', 'Migros']));
    expect(server.containsKey('Lokanta'), isFalse, reason: 'silme buluta ulaştı');
    expect((server['Migros']!['amount'] as num).toDouble(), 900, reason: 'düzenleme buluta ulaştı');
    final budgets = h.backend.user(_email).budgets;
    expect(budgets.length, 1);
    expect(budgets.single['category_id'], 1);
    expect((budgets.single['monthly_limit'] as num).toDouble(), 2000);
    expect(h3.app.pendingCount, 0);
    expect(h3.app.offline, isFalse);
    expect(h3.app.expenses.every((e) => e.syncState == SyncState.synced), isTrue);
    expect(h3.app.budgetProgress.map((p) => p.budget.categoryId), [1]);
  });

  test('çıkışta sunucudan önbelleğe alınan fişler diskten silinir; yüklenmemiş kayıtlar kalır', () async {
    final h = await _seedOnline();
    final uid = h.app.user!.id;
    // Çevrimdışı bir kayıt: yüklenmeyi bekler.
    h.backend.offline = true;
    await h.app.saveDraft(_draft('Şok', 120, uid: 'off-sok'));
    expect((await h.local.load(uid)).cloudExpenses, isNotEmpty);

    await h.app.logout();
    final snap = await h.local.load(uid);
    expect(snap.cloudExpenses, isEmpty, reason: 'geçmiş fişler paylaşılan cihazda kalmaz');
    expect(snap.expenses.map((e) => e.merchant), ['Şok'], reason: 'yüklenmemiş kayıt kaybolmaz');
    expect(snap.budgets.every((b) => b.state != SyncState.synced), isTrue);
  });

  testWidgets('çevrimdışı önbellekten açılan Özet bölümleri bütçeyi ve projeksiyonu gösterir; çevrimdışı rozeti hata değildir', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Harness h2;
    await tester.runAsync(() async {
      final h = await _seedOnline();
      h2 = await _reopenOffline(h);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                SyncStatusBadge(app: h2.app),
                BudgetsSection(app: h2.app),
                FixedExpensesSection(app: h2.app, now: _now),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('sync-status-badge-offline')), findsOneWidget);
    expect(find.textContaining('Çevrimdışısın'), findsNothing, reason: 'büyük bant yok; yalnızca küçük rozet');
    expect(find.text('Toplam aylık bütçe'), findsOneWidget);
    expect(find.text('Market / Gıda'), findsOneWidget);
    expect(find.byKey(const Key('fixed-projection')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('fixed-projection-total'))).data, fmtMoney(500));
  });
}
