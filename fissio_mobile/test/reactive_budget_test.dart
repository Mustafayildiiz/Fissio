import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/budget_widgets.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

/// Üst widget'ı HİÇ yeniden kurulmayan bir ağaç: gerçek Özet sayfasındaki `const BudgetsSection()` durumu.
/// Bölümler appState'i kendileri dinlemiyorsa bütçe değişince yenilenmez (yalnızca tema değişimi gibi
/// InheritedWidget tetiklemeli tam yeniden kurulumlarda görünür).
Widget _staticTree(List<Widget> children) => MaterialApp(
  theme: buildTheme(brightness: Brightness.light),
  home: Scaffold(body: SingleChildScrollView(child: Column(children: children))),
);

ReceiptDraft _draft(String merchant, double amount, {int cat = 1, DateTime? date}) => ReceiptDraft(
  merchant: merchant,
  categoryId: cat,
  date: date ?? DateTime(2026, 5, 12),
  items: [ExpenseItem('kalem', amount, categoryId: cat)],
);

void main() {
  final now = DateTime(2026, 5, 15, 12);
  late Harness h;
  setUp(() => h = Harness(clock: () => now));

  testWidgets('bütçe eklenince/güncellenince/silinince Özet bölümü tema değişimi olmadan anında güncellenir', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await h.signIn('ali@x.co');
      await h.app.saveDraft(_draft('Migros', 850));
    });
    // `const` alt widget: Flutter aynı örneği yeniden kurmaz; yenileme yalnızca kendi dinleyicisinden gelmeli.
    await tester.pumpWidget(_staticTree([BudgetsSection(app: h.app), FixedExpensesSection(app: h.app, now: now)]));
    await tester.pump();
    expect(find.textContaining('aylık limit belirle'), findsOneWidget);

    await tester.runAsync(() => h.app.setBudget(1, 1000));
    await tester.pump();
    expect(find.byKey(const ValueKey('budget-fill')), findsOneWidget, reason: 'eklenen limit anında görünmeli');
    expect(find.text('Market / Gıda'), findsOneWidget);
    expect(find.text('Limitin %80\'ine ulaştın'), findsOneWidget);

    await tester.runAsync(() => h.app.setBudget(1, 800));
    await tester.pump();
    expect(find.text('Limit ${fmtMoney(50)} aşıldı'), findsOneWidget, reason: 'güncellenen limit anında yansımalı');

    await tester.runAsync(() => h.app.removeBudget(1));
    await tester.pump();
    expect(find.byKey(const ValueKey('budget-fill')), findsNothing);
    expect(find.textContaining('aylık limit belirle'), findsOneWidget);
  });

  testWidgets('fiş eklenince sabit gider projeksiyonu da anında güncellenir', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => h.signIn('ali@x.co'));
    await tester.pumpWidget(_staticTree([FixedExpensesSection(app: h.app, now: now)]));
    await tester.pump();
    expect(find.byKey(const Key('fixed-projection-total')), findsNothing);

    await tester.runAsync(
      () => h.app.saveDraft(_draft('Internet', 300, cat: 11, date: DateTime(2026, 5, 1))..recurringDay = 12),
    );
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('fixed-projection-total'))).data, fmtMoney(300));
  });
}
