import 'dart:typed_data';

import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/ocr/scan_session.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(int v) => Uint8List.fromList([v]);

void main() {
  group('ScanSession', () {
    test('ekler, boş veriyi reddeder, sırayı korur', () {
      final s = ScanSession();
      expect(s.add(_b(1)), isTrue);
      expect(s.add(Uint8List(0)), isFalse);
      expect(s.add(_b(2)), isTrue);
      expect(s.pages.map((p) => p.first), [1, 2]);
      expect(s.length, 2);
      expect(s.remaining, ScanSession.maxPages - 2);
    });

    test('altı sayfa sınırı: fazlası eklenmez, addAll eklenen sayıyı döner', () {
      final s = ScanSession();
      final added = s.addAll(List.generate(9, (i) => _b(i + 1)));
      expect(added, ScanSession.maxPages);
      expect(s.isFull, isTrue);
      expect(s.add(_b(99)), isFalse);
      expect(s.remaining, 0);
    });

    test('initial sayfalar limite kadar alınır', () {
      final s = ScanSession(initial: List.generate(8, (i) => _b(i + 1)));
      expect(s.length, ScanSession.maxPages);
    });

    test('removeAt geçersiz indekste sessizce yok sayar', () {
      final s = ScanSession(initial: [_b(1), _b(2), _b(3)]);
      s.removeAt(5);
      s.removeAt(-1);
      expect(s.length, 3);
      s.removeAt(1);
      expect(s.pages.map((p) => p.first), [1, 3]);
    });

    test('move: onReorderItem semantiği (newIndex çıkarma sonrası konum)', () {
      final s = ScanSession(initial: [_b(1), _b(2), _b(3), _b(4)]);
      s.move(0, 2); // 1'i 3'ün olduğu konuma taşı
      expect(s.pages.map((p) => p.first), [2, 3, 1, 4]);
      s.move(3, 0);
      expect(s.pages.map((p) => p.first), [4, 2, 3, 1]);
      s.move(1, 1); // aynı yer
      s.move(9, 0); // geçersiz
      expect(s.pages.map((p) => p.first), [4, 2, 3, 1]);
    });

    test('pages değiştirilemez liste döner', () {
      final s = ScanSession(initial: [_b(1)]);
      expect(() => s.pages.add(_b(2)), throwsUnsupportedError);
    });
  });

  group('Fiş fotoğrafı modelleri', () {
    test('Expense.fromJson image_ids okur; yoksa boş', () {
      final base = {
        'id': 1,
        'merchant': 'BIM',
        'amount': 10,
        'date': '2026-01-02',
        'category_id': 1,
        'category_name': 'Market',
      };
      expect(Expense.fromJson({...base, 'image_ids': [3, 4]}).imageIds, [3, 4]);
      expect(Expense.fromJson(base).imageIds, isEmpty);
    });

    test('ReceiptDraft varsayılan pendingImages boş ve değiştirilebilir', () {
      final d = ReceiptDraft();
      expect(d.pendingImages, isEmpty);
      d.pendingImages.add(_b(1));
      expect(d.pendingImages.length, 1);
    });
  });
}
