import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/budgets.dart' show monthTotalFor;
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Gün/ay dönümünde (gece yarısı, ay başı) arayüzün eski günde kalmaması: başka bir olay olmasa da
/// uygulama ön plana gelince/zamanlayıcıda dinleyiciler uyandırılır.
void main() {
  test('uygulama öne gelince gün değişmişse dinleyiciler uyandırılır; aynı günde uyandırılmaz', () async {
    var now = DateTime(2026, 5, 31, 23, 50);
    final h = Harness(clock: () => now);
    await h.signIn('ali@x.co');
    await h.app.saveDraft(ReceiptDraft(
      merchant: 'Migros',
      categoryId: 1,
      date: DateTime(2026, 5, 20),
      items: [ExpenseItem('kalem', 100, categoryId: 1)],
    ));
    await h.settle();

    var notified = 0;
    h.app.addListener(() => notified++);

    now = DateTime(2026, 5, 31, 23, 59);
    await h.app.onAppResumed();
    await h.settle();
    final sameDay = notified;

    now = DateTime(2026, 6, 1, 0, 5); // ay dönümü
    await h.app.onAppResumed();
    await h.settle();
    expect(notified, greaterThan(sameDay), reason: 'gün değişince dinleyiciler uyandırılmalı');
    // Haziran ayı henüz harcama yok: ay toplamı sıfırlandı.
    expect(monthTotalFor(h.app.expenses, h.app.activeProfileId, now), 0);
  });
}
