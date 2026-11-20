import 'dart:typed_data';

import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/data/data_transfer.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/ocr/ocr_engine.dart';
import 'package:fissio_mobile/receipt_parser/digital_receipt.dart';
import 'package:fissio_mobile/receipt_parser/parser.dart';
import 'package:fissio_mobile/services/pdf_reader.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';
import 'support/fakes.dart';

const _ettn = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

/// Metin katmanlı e-arşiv fatura PDF'inden çıkan tipik metin.
const _eInvoice = '''
ACME GIDA TICARET A.S.
VKN: 1750051846
e-Arşiv Fatura
ETTN: F47AC10B-58CC-4372-A567-0E02B2C3D479
Fatura No: GIB2026000000123
Fatura Tarihi: 05-11-2026
Mal Hizmet Açıklaması Miktar Birim Fiyat Tutar
Süt 1 L 2 Adet 30,00 TL 60,00 TL
Ekmek 1 Adet 15,00 TL 15,00 TL
Mal Hizmet Toplam Tutarı 75,00 TL
Hesaplanan KDV (%10) 7,50 TL
Ödenecek Tutar 82,50 TL
''';

void main() {
  group('belge kimliği (ETTN / VKN_FaturaNo)', () {
    test('normalizeDocumentNo: yalnızca ETTN UUID ya da VKN_FaturaNo; kısa numaralar asla', () {
      expect(normalizeDocumentNo(' $_ettn '), _ettn);
      expect(normalizeDocumentNo(_ettn.toUpperCase()), _ettn, reason: 'ETTN küçük harf');
      expect(normalizeDocumentNo('1750051846_gib2026000000123'), '1750051846_GIB2026000000123');
      for (final bad in ['0468', '01D', 'FIS NO 0468', '527212', '15024061', 'f47ac10b58cc4372a5670e02b2c3d479',
          '175005184_ABC2021000000123', '1750051846_', '1750051846_AB', '', '   ']) {
        expect(normalizeDocumentNo(bad), isNull, reason: bad);
      }
      expect(normalizeDocumentNo(null), isNull);
    });

    test('extractDocumentNo: etiketli ETTN öncelikli; yoksa VKN + biçimi tutan fatura no; fiş/sipariş no asla', () {
      expect(extractDocumentNo(_eInvoice), _ettn);
      // ETTN etiketi bir sonraki satırdaysa da okunur.
      expect(extractDocumentNo('ETTN\n$_ettn\nToplam 10,00'), _ettn);
      // Etiketsiz UUID (satıcı/mağaza kimliği) kimlik OLMAZ: her faturada aynı değer çıkabilir.
      expect(extractDocumentNo('Mağaza kodu $_ettn\nToplam 10,00'), isNull);
      expect(extractDocumentNo('Mağaza kodu $_ettn\nVKN: 1750051846\nFatura No: GIB2026000000123'), '1750051846_GIB2026000000123');
      // ETTN yoksa VKN_FaturaNo.
      const noEttn = 'ACME\nVKN: 1750051846\nFatura No: GIB2026000000123\nÖdenecek Tutar 82,50';
      expect(extractDocumentNo(noEttn), '1750051846_GIB2026000000123');
      // Kısa fiş / sipariş / Z numaraları kimlik olmaz (başka belgelerle çakışırdı).
      expect(extractDocumentNo('BIM\nFIS NO : 0468\nTOPLAM *223,65'), isNull);
      expect(extractDocumentNo('Uber Eats\nSipariş Kodu: 01D\nToplam: 250,00'), isNull);
      expect(extractDocumentNo('VKN: 1750051846\nFiş No: 0298\nToplam 26,15'), isNull, reason: 'fatura no biçimi tutmuyor');
      expect(extractDocumentNo('Fatura No: GIB2026000000123\nToplam 10,00'), isNull, reason: 'VKN yok');
    });

    test('hasUsableTextLayer: metinli PDF evet, taranmış (boş/kısa) PDF hayır', () {
      expect(hasUsableTextLayer([_eInvoice]), isTrue);
      expect(hasUsableTextLayer(['', '']), isFalse);
      expect(hasUsableTextLayer(['12 3 4']), isFalse);
      expect(hasUsableTextLayer(['Sadece harfler ama hiç tutar yok burada yazan uzun bir cümle bulunuyor']), isFalse);
    });

    test('fatura metni fiş ayrıştırıcısından geçer: işletme, tarih, kalemler, ödenecek tutar', () {
      final r = parseReceiptText(_eInvoice, now: DateTime(2026, 11, 20));
      expect(r.merchant, 'ACME GIDA TICARET A.S.');
      expect(r.date, '2026-11-05');
      expect(r.amount, 82.5);
      expect(r.items.map((i) => i.amount), [60.0, 15.0]);
    });
  });

  group('AppState.readDigitalReceipt', () {
    late Harness h;
    late FakePdfReader reader;
    late PdfReader saved;

    setUp(() async {
      saved = pdfReader;
      reader = FakePdfReader(textPages: [_eInvoice]);
      pdfReader = reader;
      h = Harness(clock: () => DateTime(2026, 11, 20));
      await h.signIn('ali@x.co');
    });
    tearDown(() => pdfReader = saved);

    test('metin katmanlı PDF: OCR yok, motor "pdf", belge kimliği taslakta; senkron açıkken yalnızca METİN sunucuya gider', () async {
      final d = await h.app.readDigitalReceipt('/tmp/fatura.pdf');
      expect(reader.paths, ['/tmp/fatura.pdf']);
      expect(reader.renderCalls, 0, reason: 'metin katmanı varsa sayfalar görsele çevrilmez');
      expect(d.ocrEngine, kStoredPdf);
      expect(d.documentNo, _ettn);
      expect(h.backend.scanCalls, 0, reason: 'OCR çağrısı yok');
      expect(h.backend.parseTexts, hasLength(1), reason: 'senkron açık + çevrimiçi: metin sunucu ayrıştırıcısına');
      expect(h.backend.parseTexts.single, contains('Ödenecek Tutar 82,50'));
      expect(d.toRequestBody()['document_no'], _ettn);
      expect(d.toRequestBody()['ocr_engine'], 'pdf');
    });

    test('senkron AÇIK (sunucu ayrıştırması): KDV dışı kalemler yine ödenecek tutara tamamlanır', () async {
      h.backend.parseOverride = {
        'merchant': 'ACME GIDA TICARET A.S.',
        'amount': 82.5,
        'category_id': 1,
        'category_name': 'Market / Gıda',
        'needs_manual': false,
        'needs_review': false,
        'items': [
          {'name': 'Süt', 'amount': 60.0, 'category_id': 1},
          {'name': 'Ekmek', 'amount': 15.0, 'category_id': 1},
        ],
      };
      final d = await h.app.readDigitalReceipt('/tmp/fatura.pdf');
      expect(h.backend.parseTexts, hasLength(1));
      expect(d.savedAmount, 82.5);
      expect(d.items.last.name, 'KDV');
      expect(d.items.last.amount, 7.5);
    });

    test('kalem toplamı zaten ödenecek tutarsa ya da uyuşmazlık bayraklıysa KDV kalemi eklenmez', () async {
      await h.app.setSyncEnabled(false);
      reader.textPages = [_eInvoice.replaceAll('Ödenecek Tutar 82,50 TL', 'Ödenecek Tutar 75,00 TL')];
      final d = await h.app.readDigitalReceipt('/tmp/kdvsiz.pdf');
      expect(d.items.any((i) => i.name == 'KDV'), isFalse);
      expect(d.savedAmount, 75.0);
    });

    test('senkron KAPALI: hiçbir istek atılmaz (yerel ayrıştırma), belge yine okunur', () async {
      await h.app.setSyncEnabled(false);
      final before = h.backend.log.length;
      final d = await h.app.readDigitalReceipt('/tmp/fatura.pdf');
      expect(h.backend.log.length, before, reason: 'senkron kapalıyken ağ yok');
      expect(d.documentNo, _ettn);
      // E-fatura kalemleri KDV'siz: fark ayrı "KDV" kalemi olur, kaydedilen tutar "Ödenecek Tutar" ile aynıdır.
      expect(d.savedAmount, 82.5, reason: 'KDV eksik kaydedilmemeli');
      expect(d.items.map((i) => (i.name, i.amount)), [
        ('Süt 1 L 2 Adet 30,00 TL', 60.0),
        ('Ekmek 1 Adet 15,00 TL', 15.0),
        ('KDV', 7.5),
      ]);
    });

    test('mükerrer: aynı ETTN hesapta varsa 409 duplicate_document; farklı fatura eklenebilir', () async {
      final d = await h.app.readDigitalReceipt('/tmp/fatura.pdf');
      await h.app.saveDraft(d);
      expect(h.app.expenses.single.documentNo, _ettn);

      await expectLater(
        h.app.readDigitalReceipt('/tmp/fatura-kopya.pdf'),
        throwsA(isA<ApiException>().having((e) => e.duplicateDocument, 'duplicateDocument', isTrue)),
      );
      reader.textPages = [_eInvoice.replaceAll('F47AC10B-58CC-4372-A567-0E02B2C3D479', '11111111-2222-4333-8444-555555555555')];
      expect((await h.app.readDigitalReceipt('/tmp/baska.pdf')).documentNo, '11111111-2222-4333-8444-555555555555');
    });

    test('kayıtta sunucu 409 verirse (yerel önbellek eksik) kullanıcıya mükerrer iletisi gider', () async {
      final d = await h.app.readDigitalReceipt('/tmp/fatura.pdf');
      await h.app.saveDraft(d);
      final again = ReceiptDraft.fromParsed(const ParsedReceipt(merchant: 'X', amount: 5, categoryId: 1, categoryName: 'Market / Gıda', needsManual: false))
        ..documentNo = _ettn
        ..clientUid = 'baska-uid';
      await expectLater(h.app.saveDraft(again), throwsA(isA<ApiException>().having((e) => e.duplicateDocument, 'dup', isTrue)));
    });

    test('taranmış PDF: sayfalar görsele çevrilip OCR hattına düşer (sayfa görselleri fişe eklenir)', () async {
      reader
        ..textPages = ['', '']
        ..pageImages = [Uint8List.fromList([1, 2, 3]), Uint8List.fromList([4, 5, 6])];
      final d = await h.app.readDigitalReceipt('/tmp/tarama.pdf');
      expect(reader.renderCalls, 1);
      expect(h.backend.scanCalls, 1, reason: 'sunucu OCR (otomatik mod, çevrimiçi)');
      expect(h.backend.scanFileCounts.single, 2);
      expect(d.pendingImages, hasLength(2));
      expect(d.ocrEngine, isNot(kStoredPdf), reason: 'gerçekte kullanılan OCR motoru yazılır');
    });

    test('PDF açılamazsa ApiException (kullanıcıya gösterilebilir ileti)', () async {
      reader.failure = PdfReadException('PDF dosyası açılamadı.');
      await expectLater(
        h.app.readDigitalReceipt('/tmp/bozuk.pdf'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('açılamadı'))),
      );
    });

    test('tutar okunamayan PDF: elle giriş önerilir', () async {
      reader.textPages = ['Bu belge uzun bir metin içeriyor ancak hiçbir tutar barındırmıyor ve kalem de yok sadece cümleler'];
      // Metin katmanı eşiğini geçse de tutar yok → taranmış yol: render sahtesi boş döner → hata.
      await expectLater(h.app.readDigitalReceipt('/tmp/tutarsiz.pdf'), throwsA(isA<ApiException>()));
    });
  });

  group('yedek (JSON) belge kimliğini taşır; geçersiz kimlik yok sayılır', () {
    test('gidiş-dönüş', () {
      final data = BackupData(1, DateTime(2026, 11, 20), [
        BackupProfile('p', 'Kişisel', [
          BackupExpense(
            uid: 'a', date: DateTime(2026, 11, 5), merchant: 'ACME', amount: 82.5, category: 'Diğer', note: '', items: const [],
            ocrEngine: 'pdf', documentNo: _ettn,
          ),
          BackupExpense(uid: 'b', date: DateTime(2026, 11, 6), merchant: 'B', amount: 5, category: 'Diğer', note: '', items: const []),
        ]),
      ]);
      final back = parseBackup(exportJson(data));
      expect(back.profiles.single.expenses.map((e) => e.documentNo), [_ettn, null]);
      expect(back.profiles.single.expenses.first.ocrEngine, 'pdf');
    });
  });

  group('model', () {
    test('Expense.documentNo yerel/sunucu JSON gidiş-dönüşü', () {
      final e = Expense(
        id: 1, merchant: 'a', amount: 1, date: DateTime(2026, 5, 1), categoryId: 1, categoryName: 'x', note: '', items: const [],
        documentNo: _ettn,
      );
      expect(Expense.fromLocalJson(e.toLocalJson()).documentNo, _ettn);
      expect(Expense.fromJson({'id': 1, 'merchant': 'a', 'amount': 1, 'date': '2026-05-01', 'document_no': _ettn}).documentNo, _ettn);
      expect(Expense.fromJson({'id': 1, 'merchant': 'a', 'amount': 1, 'date': '2026-05-01'}).documentNo, isNull);
      expect(ReceiptDraft.from(e).documentNo, _ettn);
      expect(ReceiptDraft().toRequestBody().containsKey('document_no'), isFalse, reason: 'fişte gönderilmez, PUT silmez');
    });
  });

  test('PDF motoru görünen adı', () {
    expect(ocrEngineDisplayName('pdf'), 'PDF / E-Fatura Ayrıştırıcı');
    expect(storedOcrEngineId('pdf'), 'pdf');
    expect(themeController, isNotNull);
  });
}
