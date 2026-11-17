import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget w) => MaterialApp(home: Scaffold(body: w));

void main() {
  test('ParsedReceipt.fromJson needs_review / items_total okur, eksikse varsayılan', () {
    final p = ParsedReceipt.fromJson({
      'merchant': 'BIM',
      'amount': 1250.75,
      'category_id': 1,
      'category_name': 'Market',
      'needs_review': true,
      'items_total': 37.5,
    });
    expect(p.needsReview, isTrue);
    expect(p.itemsTotal, 37.5);

    final legacy = ParsedReceipt.fromJson({'merchant': 'X'});
    expect(legacy.needsReview, isFalse);
    expect(legacy.itemsTotal, isNull);
  });

  test('ReceiptDraft.fromParsed ayrıştırılan fiş toplamını taşır', () {
    const parsed = ParsedReceipt(
      merchant: 'BIM',
      amount: 49.5,
      categoryId: 1,
      categoryName: 'Market',
      needsManual: false,
      items: [],
    );
    expect(ReceiptDraft.fromParsed(parsed).receiptTotal, 49.5);
  });

  test('discount_total okunur; taslak kalemler − indirimi kaydeder', () {
    final p = ParsedReceipt.fromJson({
      'merchant': 'MİGROS',
      'amount': 180.0,
      'category_id': 1,
      'category_name': 'Market',
      'items': [
        {'name': 'KAŞAR', 'amount': 120.0},
        {'name': 'ÇAY', 'amount': 30.0},
        {'name': 'KARTON SÜT', 'amount': 25.0},
        {'name': 'EKMEK', 'amount': 10.0},
      ],
      'discount_total': 5.0,
    });
    expect(p.discountTotal, 5.0);
    final d = ReceiptDraft.fromParsed(p);
    expect(d.discount, 5.0);
    expect(d.itemsTotal, 185.0);
    expect(d.savedAmount, 180.0);
    expect(TotalMismatchBanner.mismatch(d.savedAmount, d.receiptTotal), isFalse);

    expect(ParsedReceipt.fromJson({'merchant': 'X'}).discountTotal, 0);
  });

  test('kalemsiz ayrıştırmada indirim düşülmez (tek satır zaten fiş toplamı)', () {
    const p = ParsedReceipt(
      merchant: 'BIM',
      amount: 45,
      categoryId: 1,
      categoryName: 'Market',
      needsManual: false,
      discountTotal: 5,
    );
    final d = ReceiptDraft.fromParsed(p);
    expect(d.discount, 0);
    expect(d.savedAmount, 45);
  });

  test('netTotal: indirim kalemlerden büyükse kalem toplamı korunur', () {
    expect(netTotal(185, 5), 180);
    expect(netTotal(185, 0), 185);
    expect(netTotal(3, 5), 3);
    expect(netTotal(0.3, 0.1), 0.2);
  });

  test('düzenlemede indirim kayıtlı tutardan geri türetilir', () {
    final e = Expense.fromJson({
      'id': 7,
      'merchant': 'MİGROS',
      'amount': 180.0,
      'date': '2026-05-12',
      'category_id': 1,
      'category_name': 'Market',
      'items': [
        {'name': 'A', 'amount': 120.0},
        {'name': 'B', 'amount': 65.0},
      ],
    });
    final d = ReceiptDraft.from(e);
    expect(d.discount, 5.0);
    expect(d.savedAmount, 180.0);
  });

  test('mismatch: 0,01 ve üzeri fark uyarı sayılır', () {
    expect(TotalMismatchBanner.mismatch(37.5, 1250.75), isTrue);
    expect(TotalMismatchBanner.mismatch(49.5, 49.5), isFalse);
    expect(TotalMismatchBanner.mismatch(49.504, 49.5), isFalse);
    expect(TotalMismatchBanner.mismatch(10, null), isFalse);
  });

  testWidgets('uyarı farklı toplamlar için görünür, eşitse görünmez', (tester) async {
    await tester.pumpWidget(
      _wrap(const TotalMismatchBanner(itemsTotal: 37.5, receiptTotal: 1250.75)),
    );
    expect(find.textContaining('fiş toplamından'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(const TotalMismatchBanner(itemsTotal: 49.5, receiptTotal: 49.5)),
    );
    expect(find.textContaining('fiş toplamından'), findsNothing);

    await tester.pumpWidget(
      _wrap(const TotalMismatchBanner(itemsTotal: 10, receiptTotal: null)),
    );
    expect(find.textContaining('fiş toplamından'), findsNothing);
  });
}
