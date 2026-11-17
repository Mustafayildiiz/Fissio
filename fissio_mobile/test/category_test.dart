import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget w) => MaterialApp(home: Scaffold(body: w));

/// Sunucunun `/receipts/scan` `parsed` çıktısına benzer örnek (karma BİM fişi).
Map<String, dynamic> _parsedJson({bool review = false}) => {
  'merchant': 'BİM BİRLEŞİK MAĞAZALAR A.Ş.',
  'amount': 100.0,
  'category_id': review ? 11 : 1,
  'category_name': review ? 'Diğer' : 'Market / Gıda',
  'category_source': review ? 'fallback' : 'merchant',
  'category_needs_review': review,
  'category_candidates': [
    {'id': 1, 'name': 'Market / Gıda', 'score': 0.9},
    {'id': 8, 'name': 'Ev / Yaşam', 'score': 0.4},
  ],
  'items': [
    {
      'name': 'SÜT 1L',
      'amount': 34.5,
      'category_id': 1,
      'category_name': 'Market / Gıda',
      'category_confidence': 0.9,
      'category_source': 'keyword',
    },
    {
      'name': 'DETERJAN',
      'amount': 65.5,
      'category_id': 8,
      'category_name': 'Ev / Yaşam',
      'category_confidence': 0.9,
      'category_source': 'keyword',
    },
    {
      'name': 'ZZZ',
      'amount': 0.0,
      'category_id': 11,
      'category_name': 'Diğer',
      'category_source': 'fallback',
      'category_review': true,
    },
  ],
};

void main() {
  group('modeller', () {
    test('ParsedReceipt kategori alanlarını okur; eski yanıtta varsayılanlar', () {
      final p = ParsedReceipt.fromJson(_parsedJson());
      expect(p.categorySource, 'merchant');
      expect(p.categoryNeedsReview, isFalse);
      expect(p.categoryCandidates.map((c) => c.name), ['Market / Gıda', 'Ev / Yaşam']);
      expect(p.items[1].categoryId, 8);
      expect(p.items[1].categoryName, 'Ev / Yaşam');
      expect(p.items[1].categoryConfidence, 0.9);
      expect(p.items[2].categoryReview, isTrue);

      final legacy = ParsedReceipt.fromJson({'merchant': 'X', 'items': [{'name': 'A', 'amount': 1}]});
      expect(legacy.categoryNeedsReview, isFalse);
      expect(legacy.categoryCandidates, isEmpty);
      expect(legacy.items.single.categoryId, isNull);
    });

    test('category_needs_review needs_review (toplam uyuşmazlığı) ile karışmaz', () {
      final j = _parsedJson(review: true)..['needs_review'] = false;
      final p = ParsedReceipt.fromJson(j);
      expect(p.categoryNeedsReview, isTrue);
      expect(p.needsReview, isFalse);
    });

    test('fromParsed otomatik kategoriyi varsayılan seçili getirir ve öneriyi saklar', () {
      final d = ReceiptDraft.fromParsed(ParsedReceipt.fromJson(_parsedJson()));
      expect(d.categoryId, 1);
      expect(d.suggestedCategoryId, 1);
      expect(d.categoryAutoAssigned, isTrue);
      expect(d.categoryNeedsReview, isFalse);
      expect(d.items.map((i) => i.categoryId), [1, 8, 11]);
      expect(d.items.map((i) => i.suggestedCategoryId), [1, 8, 11]);
      expect(d.items[2].categoryReview, isTrue);
    });

    test('düşük güvenli (Diğer) fiş seçili gelir ama kontrol bayrağı açıktır', () {
      final d = ReceiptDraft.fromParsed(ParsedReceipt.fromJson(_parsedJson(review: true)));
      expect(d.categoryId, 11);
      expect(d.categoryNeedsReview, isTrue);
      expect(d.categoryCandidates, hasLength(2));
    });

    test('kategorisi atanamayan fiş (id 0) seçimsiz gelir', () {
      final d = ReceiptDraft.fromParsed(
        const ParsedReceipt(merchant: 'X', categoryId: 0, categoryName: 'Diğer', needsManual: true),
      );
      expect(d.categoryId, isNull);
      expect(d.suggestedCategoryId, isNull);
      expect(d.categoryAutoAssigned, isFalse);
    });

    test('ExpenseItem.fromJson: category_id 0/yok → atanmamış; Expense eksik alanlara toleranslı', () {
      expect(ExpenseItem.fromJson({'name': 'A', 'amount': 1, 'category_id': 0}).categoryId, isNull);
      final e = Expense.fromJson({
        'id': 1,
        'merchant': 'BİM',
        'amount': 10.0,
        'date': '2026-05-12',
        'category_id': 1,
        'category_name': 'Market / Gıda',
        'items': [
          {'name': 'EKMEK', 'amount': 10.0, 'category_id': 1, 'category_name': 'Market / Gıda'},
          {'name': 'ESKİ', 'amount': 1.0},
        ],
      });
      expect(e.items[0].categoryId, 1);
      expect(e.items[1].categoryId, isNull);
      // Düzenleme taslağı kalem kategorilerini korur, öneri taşımaz (düzenleme öğrenme tetiklemez).
      final d = ReceiptDraft.from(e);
      expect(d.items[0].categoryId, 1);
      expect(d.items[0].suggestedCategoryId, isNull);
      expect(d.suggestedCategoryId, isNull);
    });

    test('CategoryRule.fromJson', () {
      final r = CategoryRule.fromJson({
        'id': 5,
        'kind': 'merchant',
        'pattern': 'yildiz gida',
        'category_id': 2,
        'category_name': 'Restoran / Kafe',
        'hits': 3,
      });
      expect((r.id, r.kind, r.pattern, r.categoryId, r.hits), (5, 'merchant', 'yildiz gida', 2, 3));
    });
  });

  group('toRequestBody (kayıt gövdesi, düzeltmeden öğrenme)', () {
    test('onaylanan öneri: category_id == suggested_category_id', () {
      final d = ReceiptDraft.fromParsed(ParsedReceipt.fromJson(_parsedJson()));
      final b = d.toRequestBody();
      expect(b['category_id'], 1);
      expect(b['suggested_category_id'], 1);
      final items = b['items'] as List;
      expect(items[1], {'name': 'DETERJAN', 'amount': 65.5, 'category_id': 8, 'suggested_category_id': 8});
    });

    test('kullanıcı fiş ve kalem kategorisini değiştirince öneri korunur (sunucu farkı öğrenir)', () {
      final d = ReceiptDraft.fromParsed(ParsedReceipt.fromJson(_parsedJson()));
      d.categoryId = 2;
      d.items[0].categoryId = 9;
      final b = d.toRequestBody();
      expect(b['category_id'], 2);
      expect(b['suggested_category_id'], 1);
      expect(d.categoryAutoAssigned, isFalse);
      final first = (b['items'] as List).first as Map;
      expect(first['category_id'], 9);
      expect(first['suggested_category_id'], 1);
    });

    test('manuel fiş: öneri alanları yok, kategorisiz kalem category_id göndermez', () {
      final d = ReceiptDraft(
        merchant: 'Bakkal',
        categoryId: 3,
        date: DateTime(2026, 5, 2),
        items: [ExpenseItem('Ekmek', 10)],
      );
      final b = d.toRequestBody();
      expect(b.containsKey('suggested_category_id'), isFalse);
      expect(b['date'], '2026-05-02');
      expect((b['items'] as List).single, {'name': 'Ekmek', 'amount': 10.0});
    });
  });

  group('widget', () {
    testWidgets('CategoryReviewBanner yalnızca gerekirse görünür ve adayı seçtirir', (tester) async {
      int? picked;
      await tester.pumpWidget(
        _wrap(CategoryReviewBanner(visible: false, candidates: const [(1, 'Market / Gıda')], onPick: (_) {})),
      );
      expect(find.textContaining('Kategori otomatik'), findsNothing);

      await tester.pumpWidget(
        _wrap(
          CategoryReviewBanner(
            visible: true,
            candidates: const [(1, 'Market / Gıda'), (8, 'Ev / Yaşam')],
            onPick: (id) => picked = id,
          ),
        ),
      );
      expect(find.textContaining('Kategori otomatik'), findsOneWidget);
      await tester.tap(find.text('Ev / Yaşam'));
      expect(picked, 8);
    });

    testWidgets('ItemCategoryChip ad / "Kategori seç" gösterir ve dokunulabilir', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(ItemCategoryChip(name: 'Ev / Yaşam', review: true, onTap: () => taps++)));
      expect(find.text('Ev / Yaşam'), findsOneWidget);
      await tester.tap(find.text('Ev / Yaşam'));
      expect(taps, 1);

      await tester.pumpWidget(_wrap(ItemCategoryChip(name: null, onTap: () {})));
      expect(find.text('Kategori seç'), findsOneWidget);
    });

    testWidgets('AutoBadge etiketi', (tester) async {
      await tester.pumpWidget(_wrap(const AutoBadge()));
      expect(find.text('Otomatik'), findsOneWidget);
    });
  });
}
