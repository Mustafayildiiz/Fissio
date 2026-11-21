import 'package:fissio_mobile/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Açılış/sekme performansı: yenilemeler birleşir, kabuk açılışı yinelenen tam yenileme yapmaz.

int _catCalls(Harness h) => h.backend.requests.where((u) => u.path == '/categories').length;

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.signIn('ali@x.co');
    await h.settle(60); // oturum açmanın arka plan flush'ı bitsin (kilit boşalsın)
  });

  test('ardışık refresh() istekleri: çalışan 1 + bekleyen 1 (üçüncü bekleyene katılır)', () async {
    final before = _catCalls(h);
    final a = h.app.refresh();
    final b = h.app.refresh(); // çalışan yenilemeye değil, sıradaki taze yenilemeye
    final c = h.app.refresh(); // aynı bekleyen yenileme
    expect(identical(b, c), isTrue, reason: 'bekleyen yenileme paylaşılır');
    await Future.wait([a, b, c]);
    expect(_catCalls(h) - before, 2, reason: 'üç istek iki tam yenilemeye indi');
  });

  test('refresh() çalışmakta olan bir yenilemeye katılmaz: değişiklik sonrası istenen yenileme taze veri görür', () async {
    final a = h.app.refresh();
    final b = h.app.refresh();
    expect(identical(a, b), isFalse);
    await Future.wait([a, b]);
  });

  test('refreshIfStale: yakın zamanda yenilendiyse istek atmaz; bayatsa ya da çalışıyorsa uygun davranır', () async {
    final before = _catCalls(h);
    await h.app.refreshIfStale(); // oturum açma yenilemesi az önce bitti
    expect(_catCalls(h), before, reason: 'yinelenen tam yenileme yok');

    await h.app.refreshIfStale(maxAge: Duration.zero); // bayat sayılır
    expect(_catCalls(h) - before, 1);

    final running = h.app.refresh();
    final joined = h.app.refreshIfStale(); // çalışan/bekleyen yenilemeyi bekler, yenisini başlatmaz
    await Future.wait([running, joined]);
    expect(_catCalls(h) - before, 2, reason: 'ek yenileme başlatılmadı');
  });

  test('yenileme verisi: üç paralel istek de uygulanır (kategoriler, profiller, fişler)', () async {
    await h.app.saveDraft(ReceiptDraft(merchant: 'Migros', categoryId: 1, date: DateTime(2026, 5, 12), items: [ExpenseItem('kalem', 50, categoryId: 1)]));
    await h.app.refresh();
    expect(h.app.categories, isNotEmpty);
    expect(h.app.profiles, isNotEmpty);
    expect(h.app.expenses.length, 1);
  });
}
