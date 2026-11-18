import 'dart:typed_data';

import 'package:fissio_mobile/budgets.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/budget_widgets.dart';
import 'package:fissio_mobile/pages/receipt_detail_page.dart';
import 'package:fissio_mobile/pages/receipt_form_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'support/fake_backend.dart';

Widget _app(Widget home, {Brightness brightness = Brightness.light}) =>
    MaterialApp(theme: buildTheme(brightness: brightness), home: Scaffold(body: home));

Color _fill(WidgetTester tester) =>
    tester.widget<ColoredBox>(find.byKey(const ValueKey('budget-fill'))).color;

ReceiptDraft _draft(String merchant, double amount, {int cat = 1, DateTime? date, int recurringDay = 0, int? id, String? uid}) =>
    ReceiptDraft(
      id: id,
      clientUid: uid,
      merchant: merchant,
      categoryId: cat,
      date: date ?? DateTime(2026, 5, 12),
      items: [ExpenseItem('kalem', amount, categoryId: cat)],
      recurringDay: recurringDay,
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('ilerleme çubuğu: normal = vurgu, %80 = sarı, %100+ = kırmızı (${brightness.name})', (tester) async {
      final c = brightness == Brightness.dark ? FissioColors.dark() : FissioColors.light();
      Future<void> show(double ratio, BudgetLevel level) async {
        await tester.pumpWidget(_app(BudgetBar(ratio: ratio, level: level), brightness: brightness));
      }

      await show(.5, BudgetLevel.ok);
      expect(_fill(tester), c.accent);
      await show(.8, budgetLevel(80, 100));
      expect(_fill(tester), c.warn, reason: '%80 → sarı');
      await show(.99, budgetLevel(99, 100));
      expect(_fill(tester), c.warn);
      await show(1.0, budgetLevel(100, 100));
      expect(_fill(tester), c.danger, reason: '%100 → kırmızı');
      await show(1.7, budgetLevel(170, 100));
      expect(_fill(tester), c.danger);
      // Aşımda çubuk taşmaz: dolu kalır.
      final box = tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
      expect(box.widthFactor, 1.0);
    });
  }

  group('Özet: bütçeler ve sabit giderler', () {
    late Harness h;
    final now = DateTime(2026, 5, 15, 12);
    setUp(() => h = Harness(clock: () => now));

    testWidgets('limit/harcama çubukları eşiğe göre renk değiştirir; sabit gider projeksiyonu görünür', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await h.signIn('ali@x.co');
        await h.app.setBudget(1, 1000);
        await h.app.setBudget(2, 500);
        await h.app.saveDraft(_draft('Migros', 850)); // Market %85 → sarı
        await h.app.saveDraft(_draft('Lokanta', 600, cat: 2)); // Restoran %120 → kırmızı
        await h.app.saveDraft(_draft('Enerjisa', 400, cat: 11, date: DateTime(2026, 4, 25), recurringDay: 25));
        await h.app.saveDraft(_draft('Enerjisa', 420, cat: 11, date: DateTime(2026, 3, 25), recurringDay: 25));
        await h.app.saveDraft(_draft('Internet', 300, cat: 11, date: DateTime(2026, 5, 1), recurringDay: 12));
      });
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: Column(
              children: [BudgetsSection(app: h.app), FixedExpensesSection(app: h.app, now: now)],
            ),
          ),
        ),
      );
      await tester.pump();
      final c = FissioColors.light();

      expect(find.text('BÜTÇELER · BU AY'), findsOneWidget);
      final fills = tester.widgetList<ColoredBox>(find.byKey(const ValueKey('budget-fill'))).map((e) => e.color).toList();
      expect(fills.length, 2);
      // Kategori adına göre sıralı: Market / Gıda (sarı), Restoran / Kafe (kırmızı).
      expect(fills, [c.warn, c.danger]);
      expect(find.text('Limit ${fmtMoney(100)} aşıldı'), findsOneWidget);
      expect(find.text('Limitin %80\'ine ulaştın'), findsOneWidget);

      // Aylık sabit gider projeksiyonu: Enerjisa (en son 400, çift sayılmaz) + Internet 300.
      expect(find.byKey(const Key('fixed-projection')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('fixed-projection-total'))).data, fmtMoney(700));
      expect(find.text('2 tekrarlayan gider'), findsOneWidget);
      // Yaklaşan ödemeler: en yakın önce (Internet 12 Haziran, Enerjisa 25 Mayıs → önce Enerjisa).
      expect(find.text('Enerjisa'), findsOneWidget);
      expect(find.text('Internet'), findsOneWidget);
    });

    testWidgets('bütçe ve sabit gider yokken yönlendirici boş durumlar', (tester) async {
      await tester.runAsync(() async => h.signIn('ali@x.co'));
      await tester.pumpWidget(
        _app(SingleChildScrollView(child: Column(children: [BudgetsSection(app: h.app), FixedExpensesSection(app: h.app, now: now)]))),
      );
      await tester.pump();
      expect(find.textContaining('aylık limit belirle'), findsOneWidget);
      expect(find.textContaining('Her ay tekrarlanır'), findsOneWidget);
      expect(find.byKey(const Key('fixed-projection-total')), findsNothing);
    });
  });

  group('fiş detayı', () {
    late Harness h;
    setUp(() => h = Harness());

    testWidgets('kağıt fişin sağ üst köşesindeki kamera ikonu kaldırıldı; fotoğraf alanı çalışır', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late int id;
      await tester.runAsync(() async {
        await h.signIn('ali@x.co');
        await h.app.saveDraft(_draft('BIM', 50));
        id = h.app.expenses.single.id;
        // Sunucudaki fişe fotoğraf bağlı (eskiden başlıkta kamera ikonu çıkaran durum).
        await h.app.addImages(h.app.expenses.single, [Uint8List.fromList([1, 2, 3, 4])]);
      });
      expect(h.app.expenses.single.imageIds, isNotEmpty);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ReceiptDetailPage(id: id, app: h.app)));
      await tester.pump();
      expect(find.byIcon(LucideIcons.camera), findsNothing, reason: 'sağ üstteki kamera ikonu yok');
      // Fiş içeriği ve fotoğraf şeridi (mevcut görüntüleme akışı) bozulmadan duruyor.
      expect(find.text('BIM'), findsOneWidget);
      expect(find.text('Fiş fotoğrafları (1)'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('liste görünümü de ikonsuz; tekrarlayan fişte bilgi notu görünür', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late int id;
      await tester.runAsync(() async {
        await h.signIn('ali@x.co');
        await h.app.saveDraft(_draft('Enerjisa', 400, recurringDay: 25));
        id = h.app.expenses.single.id;
      });
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ReceiptDetailPage(id: id, app: h.app)));
      await tester.pump();
      expect(find.byKey(const Key('recurring-note')), findsOneWidget);
      expect(find.textContaining('ayın 25. günü'), findsOneWidget);
      expect(find.byIcon(LucideIcons.camera), findsNothing);
    });
  });

  group('fiş formu: Her ay tekrarlanır', () {
    testWidgets('anahtar ödeme günü ve hatırlatıcı satırlarını açar/kapatır', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final draft = ReceiptDraft(date: DateTime(2026, 5, 17));
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ReceiptFormPage(initialDraft: draft)));
      await tester.pump();
      expect(find.text('Her ay tekrarlanır'), findsOneWidget);
      expect(find.byKey(const Key('recurring-day')), findsNothing);

      await tester.tap(find.byKey(const Key('recurring-switch')));
      await tester.pump();
      expect(draft.recurringDay, 17, reason: 'varsayılan ödeme günü fiş tarihinin günü');
      expect(find.text('Ayın 17. günü'), findsOneWidget);
      expect(find.byKey(const Key('recurring-remind-switch')), findsOneWidget);

      await tester.tap(find.byKey(const Key('recurring-remind-switch')));
      await tester.pump();
      expect(draft.recurringRemind, isFalse);

      await tester.tap(find.byKey(const Key('recurring-switch')));
      await tester.pump();
      expect(draft.recurringDay, 0);
      expect(find.byKey(const Key('recurring-day')), findsNothing);
    });

    testWidgets('düzenlemede mevcut işaret yüklenir', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final e = Expense(
        id: 5,
        merchant: 'Enerjisa',
        amount: 400,
        date: DateTime(2026, 4, 25),
        categoryId: 1,
        categoryName: 'Market',
        note: '',
        items: const [],
        recurringDay: 25,
      );
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ReceiptFormPage(initial: e)));
      await tester.pump();
      expect(tester.widget<Switch>(find.byKey(const Key('recurring-switch'))).value, isTrue);
      expect(find.text('Ayın 25. günü'), findsOneWidget);
    });
  });
}
