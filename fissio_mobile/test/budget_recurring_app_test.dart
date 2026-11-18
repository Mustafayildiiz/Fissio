import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

ReceiptDraft _draft(
  String merchant,
  double amount, {
  int cat = 1,
  DateTime? date,
  int recurringDay = 0,
  bool remind = true,
  int? id,
  String? uid,
}) => ReceiptDraft(
  id: id,
  clientUid: uid,
  merchant: merchant,
  categoryId: cat,
  date: date ?? DateTime(2026, 5, 12),
  items: [ExpenseItem('kalem', amount, categoryId: cat)],
  recurringDay: recurringDay,
  recurringRemind: remind,
);

void main() {
  final now = DateTime(2026, 5, 15, 12);
  late Harness h;

  setUp(() => h = Harness(clock: () => now));

  group('bütçe bildirimleri (%80 / %100, aynı ay + eşik için tek bildirim)', () {
    test('eşikler ilk kez aşılınca bir bildirim; tekrar fişlerde spam yok', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(1, 1000);
      expect(h.app.budgets.single.limit, 1000);
      expect(h.app.budgets.single.state, SyncState.synced);

      await h.app.saveDraft(_draft('A', 700));
      expect(h.notifier.shown, isEmpty, reason: '%70: bildirim yok');

      await h.app.saveDraft(_draft('B', 150)); // %85
      expect(h.notifier.shown.length, 1);
      expect(h.notifier.shown.single.title, contains('%80'));
      expect(h.app.budgetProgress.single.level.name, 'warning');

      await h.app.saveDraft(_draft('C', 20)); // %87: aynı eşik
      expect(h.notifier.shown.length, 1, reason: 'aynı ay aynı eşik tekrarlanmaz');

      await h.app.saveDraft(_draft('D', 200)); // %107
      expect(h.notifier.shown.length, 2);
      expect(h.notifier.shown.last.title, contains('aşıldı'));
      expect(h.app.budgetProgress.single.level.name, 'exceeded');

      await h.app.saveDraft(_draft('E', 50));
      expect(h.notifier.shown.length, 2, reason: '%100 da bir kez');
    });

    test('tek fiş iki eşiği birden geçerse yalnızca %100 bildirimi', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(1, 1000);
      await h.app.saveDraft(_draft('Büyük', 1300));
      expect(h.notifier.shown.length, 1);
      expect(h.notifier.shown.single.title, contains('aşıldı'));
      await h.app.saveDraft(_draft('Küçük', 10));
      expect(h.notifier.shown.length, 1);
    });

    test('fiş güncellenince de denetlenir (düzenleme eşiği ilk kez aşırsa bildirim)', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(1, 1000);
      await h.app.saveDraft(_draft('A', 100, uid: 'a1'));
      expect(h.notifier.shown, isEmpty);
      final id = h.app.expenses.single.id;
      await h.app.saveDraft(_draft('A', 900, id: id, uid: 'a1'));
      expect(h.notifier.shown.length, 1);
      expect(h.notifier.shown.single.title, contains('%80'));
    });

    test('bildirim yalnızca fişin profili ve ilgili kategori için; "gönderildi" kaydı yeniden açılışta korunur', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(1, 1000);
      await h.app.createProfile('Ev');
      await h.app.saveDraft(_draft('Ev fişi', 950)); // Ev profilinde bütçe yok
      expect(h.notifier.shown, isEmpty);
      await h.app.selectProfile(h.app.profiles.first);
      await h.app.saveDraft(_draft('Kişisel', 900)); // Kişisel: %90
      expect(h.notifier.shown.length, 1);

      // Aynı hesapla yeni örnek (uygulama yeniden açıldı): aynı ay için tekrar bildirim yok.
      final h2 = Harness(backend: h.backend, prefs: h.prefs, local: h.local, clock: () => now);
      await h2.app.login('ali@x.co', 'Passw0rd1');
      await h2.app.saveDraft(_draft('Daha', 10));
      expect(h2.notifier.shown, isEmpty);
    });

    test('yeni ay eşiği yeniden silahlandırır', () async {
      var clock = DateTime(2026, 5, 15, 12);
      final hh = Harness(clock: () => clock);
      await hh.signIn('ali@x.co');
      await hh.app.setBudget(1, 1000);
      await hh.app.saveDraft(_draft('Mayıs', 900, date: DateTime(2026, 5, 3)));
      expect(hh.notifier.shown.length, 1);
      clock = DateTime(2026, 6, 3, 12);
      await hh.app.saveDraft(_draft('Haziran', 900, date: DateTime(2026, 6, 2)));
      expect(hh.notifier.shown.length, 2);
    });
  });

  group('bütçe saklama: bulut / çevrimdışı / yerel', () {
    test('senkron açıkken sunucuda saklanır ve profil bazında izole', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(1, 1000);
      await h.app.createProfile('Ev');
      expect(h.app.budgets, isEmpty, reason: 'Kişisel limiti Ev profilinde görünmez');
      await h.app.setBudget(2, 500);
      final srv = h.backend.user('ali@x.co').budgets;
      expect(srv.length, 2);
      expect({for (final b in srv) b['profile_id']}.length, 2, reason: 'iki farklı profile bağlı');
      await h.app.refresh();
      expect(h.app.budgets.single.categoryId, 2);
      await h.app.selectProfile(h.app.profiles.first);
      expect(h.app.budgets.single.categoryId, 1);
    });

    test('çevrimdışıyken kuyruğa alınır, bağlantı gelince buluta yüklenir', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      await h.app.setBudget(1, 2500);
      expect(h.app.budgets.single.state, SyncState.pending);
      expect(h.backend.user('ali@x.co').budgets, isEmpty);
      h.backend.offline = false;
      await h.app.flushNow(force: true);
      expect(h.app.budgets.single.state, SyncState.synced);
      expect(h.backend.user('ali@x.co').budgets.single['monthly_limit'], 2500);
    });

    test('senkron kapalıyken yalnızca cihazda; açılınca yüklenir; bulut limiti salt okunur', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(1, 1000);
      await h.app.setSyncEnabled(false);
      await expectLater(h.app.setBudget(1, 2000), throwsA(isA<ApiException>()), reason: 'bulut limiti salt okunur');
      await h.app.setBudget(2, 300);
      expect(h.app.budgets.firstWhere((b) => b.categoryId == 2).state, SyncState.localOnly);
      expect(h.backend.user('ali@x.co').budgets.length, 1, reason: 'kapalıyken sunucuya yazılmaz');
      await h.app.setSyncEnabled(true);
      expect(h.backend.user('ali@x.co').budgets.length, 2);
      expect(h.app.budgets.every((b) => b.state == SyncState.synced), isTrue);
    });

    test('limit kaldırma sunucudan da siler; çıkışta bellek temizlenir, hesaplar izole', () async {
      await h.signIn('ali@x.co');
      await h.app.setBudget(1, 1000);
      await h.app.removeBudget(1);
      expect(h.app.budgets, isEmpty);
      expect(h.backend.user('ali@x.co').budgets, isEmpty);
      await h.app.setBudget(1, 1000);
      await h.app.logout();
      await h.signIn('veli@x.co');
      expect(h.app.budgets, isEmpty, reason: 'önceki hesabın limitleri görünmez');
    });
  });

  group('tekrarlayan giderler', () {
    test('işaret sunucuya gider; projeksiyon seri başına; yaklaşan ödemeler listelenir', () async {
      await h.signIn('ali@x.co');
      await h.app.saveDraft(_draft('Enerjisa', 300, cat: 2, date: DateTime(2026, 3, 25), recurringDay: 25));
      await h.app.saveDraft(_draft('Enerjisa', 400, cat: 2, date: DateTime(2026, 4, 25), recurringDay: 25));
      await h.app.saveDraft(_draft('Market', 50));
      final sent = h.backend.expensesOf('ali@x.co');
      expect(sent.where((e) => e['recurring_day'] == 25).length, 2);
      expect(h.app.recurring.items.length, 1);
      expect(h.app.recurring.monthlyTotal, 400);
      expect(h.app.upcomingPayments.single.merchant, 'Enerjisa');
      expect(h.app.upcomingPayments.single.nextDue, DateTime.utc(2026, 5, 25));
    });

    test('çevrimdışı kuyruktaki fişin işareti de yüklemede taşınır (bulk)', () async {
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      final res = await h.app.saveDraft(_draft('Internet', 350, date: DateTime(2026, 5, 1), recurringDay: 12, remind: false, uid: 'off1'));
      expect(res.queued, isTrue);
      expect(h.app.recurring.items.single.day, 12, reason: 'yerel fiş de projeksiyona girer');
      h.backend.offline = false;
      await h.app.flushNow(force: true);
      final uploaded = h.backend.expensesOf('ali@x.co').single;
      expect(uploaded['recurring_day'], 12);
      expect(uploaded['recurring_remind'], false);
      expect(h.app.recurring.items.single.remind, isFalse);
    });

    test('ödeme hatırlatıcıları (3 gün kala + ödeme günü) planlanır, silinince / çıkışta iptal edilir', () async {
      await h.signIn('ali@x.co');
      await h.app.saveDraft(_draft('Enerjisa', 400, cat: 2, date: DateTime(2026, 4, 25), recurringDay: 25));
      await h.settle();
      expect(h.notifier.scheduled.length, 2);
      final whens = h.notifier.scheduled.values.map((s) => s.when).toList()..sort();
      expect(whens, [DateTime(2026, 5, 22, 9), DateTime(2026, 5, 25, 9)]);

      // Hatırlatıcı kapatılınca planlar kalkar.
      final id = h.app.expenses.single.id;
      await h.app.saveDraft(_draft('Enerjisa', 400, cat: 2, date: DateTime(2026, 4, 25), recurringDay: 25, remind: false, id: id, uid: h.app.expenses.single.clientUid));
      await h.settle();
      expect(h.notifier.scheduled, isEmpty);

      // Tekrar aç, sonra çıkış: tüm bildirimler temizlenir.
      await h.app.saveDraft(_draft('Enerjisa', 400, cat: 2, date: DateTime(2026, 4, 25), recurringDay: 25, id: id, uid: h.app.expenses.single.clientUid));
      await h.settle();
      expect(h.notifier.scheduled.length, 2);
      final cancelAllBefore = h.notifier.cancelAllCalls;
      await h.app.logout();
      await h.settle();
      expect(h.notifier.cancelAllCalls, greaterThan(cancelAllBefore));
      expect(h.notifier.scheduled, isEmpty);
    });
  });

  group('ana ekran widget verisi: bu ayki toplam', () {
    test('ekleme / güncelleme / silme / profil değişimi / çıkışta güncellenir', () async {
      await h.signIn('ali@x.co');
      await h.settle();
      expect(h.widget.last?.monthTotalText, '0,00 ₺');
      expect(h.widget.last?.profileName, 'Kişisel');
      expect(h.widget.last?.monthLabel, 'Mayıs 2026');

      await h.app.saveDraft(_draft('A', 100, uid: 'a1'));
      await h.app.saveDraft(_draft('B', 50.5, uid: 'b1'));
      await h.app.saveDraft(_draft('Eski ay', 999, date: DateTime(2026, 4, 30))); // bu aya girmez
      await h.settle();
      expect(h.widget.last?.monthTotalText, '150,50 ₺');

      // Güncelleme.
      final a = h.app.expenses.firstWhere((e) => e.merchant == 'A');
      await h.app.saveDraft(_draft('A', 200, id: a.id, uid: 'a1'));
      await h.settle();
      expect(h.widget.last?.monthTotalText, '250,50 ₺');

      // Silme.
      await h.app.deleteExpense(a.id);
      await h.settle();
      expect(h.widget.last?.monthTotalText, '50,50 ₺');

      // Profil değişimi: yeni profilin toplamı ve adı.
      await h.app.createProfile('Ev');
      await h.settle();
      expect(h.widget.last?.profileName, 'Ev');
      expect(h.widget.last?.monthTotalText, '0,00 ₺');
      await h.app.selectProfile(h.app.profiles.first);
      await h.settle();
      expect(h.widget.last?.profileName, 'Kişisel');
      expect(h.widget.last?.monthTotalText, '50,50 ₺');

      // Çıkış: sonraki hesap önceki kullanıcının tutarını görmesin.
      await h.app.logout();
      await h.settle();
      expect(h.widget.last, isNull, reason: 'widget verisi temizlenir');
      expect(h.widget.updates.last, isNull);
    });

    test('aynı veri tekrar tekrar gönderilmez', () async {
      await h.signIn('ali@x.co');
      await h.settle();
      final n = h.widget.updates.length;
      await h.app.refresh();
      await h.app.refresh();
      await h.settle();
      expect(h.widget.updates.length, n);
    });
  });
}
