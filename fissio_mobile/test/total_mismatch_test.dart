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
