import 'dart:convert';

import 'package:fissio_mobile/data/data_transfer.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/ocr/ocr_engine.dart';
import 'package:fissio_mobile/pages/receipt_detail_page.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

Expense _exp({String? engine, int id = 5}) => Expense(
  id: id,
  merchant: 'Migros',
  amount: 50,
  date: DateTime(2026, 5, 12),
  categoryId: 1,
  categoryName: 'Market / Gıda',
  note: '',
  items: [ExpenseItem('süt', 50, categoryId: 1)],
  clientUid: 'u-$id',
  ocrEngine: engine,
);

ReceiptDraft _draft(String uid, {String? engine}) => ReceiptDraft(
  clientUid: uid,
  merchant: 'Şok',
  categoryId: 1,
  date: DateTime(2026, 5, 12),
  items: [ExpenseItem('kalem', 120, categoryId: 1)],
  ocrEngine: engine,
);

void main() {
  group('motor kimliği eşlemesi', () {
    test('storedOcrEngineId: ondevice→mlkit, sunucu motorları aynen, bilinmeyen null', () {
      expect(storedOcrEngineId('ondevice'), 'mlkit');
      expect(storedOcrEngineId('mlkit'), 'mlkit');
      expect(storedOcrEngineId('paddleocr'), 'paddleocr');
      expect(storedOcrEngineId('custom'), 'custom');
      expect(storedOcrEngineId('unknown'), isNull);
      expect(storedOcrEngineId(null), isNull);
    });

    test('ocrEngineDisplayName', () {
      expect(ocrEngineDisplayName('paddleocr'), 'PaddleOCR');
      expect(ocrEngineDisplayName('mlkit'), 'Google ML Kit');
      expect(ocrEngineDisplayName('custom'), 'Custom OCR');
      expect(ocrEngineDisplayName(null), isNull);
      expect(ocrEngineDisplayName('x'), isNull);
    });
  });

  group('model', () {
    test('yerel JSON gidiş-dönüş; eski kayıt (anahtar yok) null', () {
      final j = _exp(engine: 'mlkit').toLocalJson();
      expect(j['ocr_engine'], 'mlkit');
      expect(Expense.fromLocalJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>).ocrEngine, 'mlkit');

      final old = _exp().toLocalJson();
      expect(old.containsKey('ocr_engine'), isFalse);
      expect(Expense.fromLocalJson(old).ocrEngine, isNull);
    });

    test('sunucu JSON okunur; taslak gövdesi yalnızca motor varsa gönderir; düzenleme taslağı motoru taşır', () {
      final base = {'id': 1, 'merchant': 'a', 'amount': 1, 'date': '2026-05-01'};
      expect(Expense.fromJson({...base, 'ocr_engine': 'paddleocr'}).ocrEngine, 'paddleocr');
      expect(Expense.fromJson({...base, 'ocr_engine': null}).ocrEngine, isNull);
      expect(Expense.fromJson(base).ocrEngine, isNull);

      expect(_draft('a').toRequestBody().containsKey('ocr_engine'), isFalse, reason: 'manuel: gönderilmez, PUT silmez');
      expect(_draft('a', engine: 'mlkit').toRequestBody()['ocr_engine'], 'mlkit');
      expect(ReceiptDraft.from(_exp(engine: 'custom')).ocrEngine, 'custom');
    });
  });

  group('kayıt akışı', () {
    test('çevrimiçi kayıt motoru sunucuya yazar; düzenleme (PUT) motoru korur', () async {
      final h = Harness();
      await h.signIn('ali@x.co');
      await h.app.saveDraft(_draft('e-online', engine: 'paddleocr'));
      expect(h.backend.expensesOf('ali@x.co').single['ocr_engine'], 'paddleocr');

      final saved = h.app.expenses.single;
      expect(saved.ocrEngine, 'paddleocr');
      final edit = ReceiptDraft.from(saved)..merchant = 'Şok 2';
      await h.app.saveDraft(edit);
      expect(h.backend.putBodies.last['ocr_engine'], 'paddleocr');
      expect(h.app.expenses.single.ocrEngine, 'paddleocr');
    });

    test('çevrimdışı kuyruk: motor cihazda kalır, bağlantı gelince toplu yüklemeyle sunucuya gider', () async {
      final h = Harness();
      await h.signIn('ali@x.co');
      h.backend.offline = true;
      await h.app.saveDraft(_draft('e-off', engine: 'mlkit'));
      expect(h.app.expenses.single.ocrEngine, 'mlkit');
      expect(h.app.expenses.single.syncState, isNot(SyncState.synced));

      h.backend.offline = false;
      await h.app.flushNow(force: true);
      expect(h.backend.expensesOf('ali@x.co').single['ocr_engine'], 'mlkit');
    });

    test('manuel fiş: motor yok', () async {
      final h = Harness();
      await h.signIn('ali@x.co');
      await h.app.saveDraft(_draft('e-man'));
      expect(h.app.expenses.single.ocrEngine, isNull);
    });
  });

  group('yedek', () {
    test('JSON yedekte motor taşınır; eski yedek (alan yok) ve geçersiz değer null olur', () {
      final data = BackupData(1, DateTime.utc(2026, 5, 20), [
        BackupProfile('p-1', 'Kişisel', [
          BackupExpense(
            uid: 'a',
            date: DateTime(2026, 5, 1),
            merchant: 'A',
            amount: 10,
            category: 'Diğer',
            note: '',
            items: const [],
            ocrEngine: 'mlkit',
          ),
          BackupExpense(uid: 'b', date: DateTime(2026, 5, 2), merchant: 'B', amount: 11, category: 'Diğer', note: '', items: const []),
        ]),
      ]);
      final text = exportJson(data);
      final back = parseBackup(text);
      expect(back.profiles.single.expenses.map((e) => e.ocrEngine), ['mlkit', null]);

      final j = jsonDecode(text) as Map<String, dynamic>;
      final es = ((j['profiles'] as List).first as Map)['expenses'] as List;
      (es.first as Map)['ocr_engine'] = '<script>';
      expect(parseBackup(jsonEncode(j)).profiles.single.expenses.first.ocrEngine, isNull);
    });
  });

  group('fiş detayı', () {
    Future<void> pump(WidgetTester tester, Harness h, Expense e) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: buildTheme(brightness: Brightness.light), home: ReceiptDetailPage(id: e.id, app: h.app)),
      );
      await tester.pump();
    }

    for (final (engine, label) in [('paddleocr', 'PaddleOCR'), ('mlkit', 'Google ML Kit')]) {
      testWidgets('motor satırı "$label" Fişi sil\'in altında görünür', (tester) async {
        late Harness h;
        late Expense e;
        await tester.runAsync(() async {
          h = Harness();
          await h.signIn('ali@x.co');
          await h.app.saveDraft(_draft('e-$engine', engine: engine));
          e = h.app.expenses.single;
        });
        await pump(tester, h, e);
        final note = find.byKey(const Key('ocr-engine-note'));
        expect(note, findsOneWidget);
        expect(tester.widget<Text>(note).data, 'İşleyen Motor: $label');
        expect(tester.getTopLeft(note).dy, greaterThan(tester.getTopLeft(find.text('Fişi sil')).dy));
      });
    }

    testWidgets('Tercihler > "Fiş detayında OCR motorunu göster" kapalıyken satır gizlenir, açılınca geri gelir', (tester) async {
      late Harness h;
      late Expense e;
      await tester.runAsync(() async {
        h = Harness();
        await h.signIn('ali@x.co');
        await h.app.saveDraft(_draft('e-toggle', engine: 'paddleocr'));
        e = h.app.expenses.single;
      });
      final prev = themeController.showOcrEngine;
      addTearDown(() => themeController.showOcrEngine = prev);
      expect(themeController.showOcrEngine, isTrue, reason: 'varsayılan açık');
      await pump(tester, h, e);
      expect(find.byKey(const Key('ocr-engine-note')), findsOneWidget);

      await tester.runAsync(() => themeController.setShowOcrEngine(false));
      await tester.pump();
      expect(find.byKey(const Key('ocr-engine-note')), findsNothing, reason: 'ayar kapalı: satır çizilmez');

      await tester.runAsync(() => themeController.setShowOcrEngine(true));
      await tester.pump();
      expect(find.byKey(const Key('ocr-engine-note')), findsOneWidget);
    });

    testWidgets('PDF ile eklenen fişte motor "PDF / E-Fatura Ayrıştırıcı" görünür', (tester) async {
      late Harness h;
      late Expense e;
      await tester.runAsync(() async {
        h = Harness();
        await h.signIn('ali@x.co');
        await h.app.saveDraft(_draft('e-pdf', engine: 'pdf'));
        e = h.app.expenses.single;
      });
      await pump(tester, h, e);
      expect(tester.widget<Text>(find.byKey(const Key('ocr-engine-note'))).data, 'İşleyen Motor: PDF / E-Fatura Ayrıştırıcı');
    });

    testWidgets('eski/manuel fişte motor satırı yok', (tester) async {
      late Harness h;
      late Expense e;
      await tester.runAsync(() async {
        h = Harness();
        await h.signIn('ali@x.co');
        await h.app.saveDraft(_draft('e-none'));
        e = h.app.expenses.single;
      });
      await pump(tester, h, e);
      expect(find.byKey(const Key('ocr-engine-note')), findsNothing);
    });
  });
}
