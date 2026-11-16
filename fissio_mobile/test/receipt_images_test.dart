import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/pages/receipt_images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Expense _expense(List<int> imageIds) => Expense(
      id: 7,
      merchant: 'BIM',
      amount: 10,
      date: DateTime(2026, 1, 2),
      categoryId: 1,
      categoryName: 'Market',
      note: '',
      items: const [],
      imageIds: imageIds,
    );

Widget _wrap(Widget w) => MaterialApp(home: Scaffold(body: w));

void main() {
  testWidgets('fotoğrafı olmayan fişte boş durum ve "Fotoğraf ekle" görünür', (tester) async {
    await tester.pumpWidget(_wrap(ReceiptImageStrip(expense: _expense(const []))));
    expect(find.text('Bu fişe henüz fotoğraf eklenmemiş.'), findsOneWidget);
    expect(find.text('Fotoğraf ekle'), findsOneWidget);
    expect(find.text('Fiş fotoğrafları'), findsOneWidget);
  });

  testWidgets('fotoğraf sayısı başlıkta ve her fotoğraf için bir önizleme', (tester) async {
    await tester.pumpWidget(_wrap(ReceiptImageStrip(expense: _expense(const [1, 2, 3]))));
    expect(find.text('Fiş fotoğrafları (3)'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(3));
  });

  testWidgets('10 fotoğrafa ulaşınca "Fotoğraf ekle" gizlenir', (tester) async {
    final ids = List.generate(10, (i) => i + 1);
    await tester.pumpWidget(_wrap(ReceiptImageStrip(expense: _expense(ids))));
    expect(find.text('Fotoğraf ekle'), findsNothing);
  });
}
