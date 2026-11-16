import 'package:fissio_mobile/models.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:fissio_mobile/pages/receipt_form_page.dart';
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
  testWidgets('fotoğrafı olmayan fişte boş durum ve "Fotoğraf ekle" görünür', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(ReceiptImageStrip(expense: _expense(const []))),
    );
    expect(find.text('Bu fişe henüz fotoğraf eklenmemiş.'), findsOneWidget);
    expect(find.text('Fotoğraf ekle'), findsOneWidget);
    expect(find.text('Fiş fotoğrafları'), findsOneWidget);
  });

  testWidgets('fotoğraf sayısı başlıkta ve her fotoğraf için bir önizleme', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(ReceiptImageStrip(expense: _expense(const [1, 2, 3]))),
    );
    expect(find.text('Fiş fotoğrafları (3)'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(3));
  });

  testWidgets('10 fotoğrafa ulaşınca "Fotoğraf ekle" gizlenir', (tester) async {
    final ids = List.generate(10, (i) => i + 1);
    await tester.pumpWidget(_wrap(ReceiptImageStrip(expense: _expense(ids))));
    expect(find.text('Fotoğraf ekle'), findsNothing);
  });

  testWidgets('fotoğraflı taslakla form taşma (overflow) olmadan çizilir', (
    tester,
  ) async {
    // 1x1 geçerli PNG
    final png = Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ),
    );
    for (final size in const [Size(360, 640), Size(320, 568)]) {
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      await tester.pumpWidget(
        MaterialApp(
          home: ReceiptFormPage(
            initialDraft: ReceiptDraft(pendingImages: [png, png, png]),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Fotoğraf ekle'), findsOneWidget);
    }
    addTearDown(tester.view.reset);
  });
}
