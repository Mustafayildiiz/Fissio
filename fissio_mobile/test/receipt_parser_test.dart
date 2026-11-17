import 'package:fissio_mobile/receipt_parser/normalize.dart';
import 'package:fissio_mobile/receipt_parser/parser.dart';
import 'package:fissio_mobile/receipt_parser/summary.dart';
import 'package:flutter_test/flutter_test.dart';

// Go `services/expense` testlerindeki vektörlerle aynı girdiler (gerçek PaddleOCR çıktıları dahil).
final _now = DateTime.utc(2026, 10, 31, 12);

const ocrBimKoltuk = '''BIM BIRLESIK MAGAZALAR A.S
HARMANMH.MEZARLIKSK.NO4
TALAS/KAYSER
B0Y0K M0KELLEFLER V.D1750051846
TARIH12.12.2019
SAAT 17:57
FIS NO0298
PAT.CIPSI PATITO %08 3,25
PAT.CIPSI PATITO %08 3,25
SOT AROMALI %08 1,00
ETI KARAM GURME 50 G %08 1,75
ETIKARAM GURME 50 G %08 1,75
200ML.MUZ.S0T %08 1,00
SUT AROMALI %08 1,00
200ML.MUZ.ST %08 1,00
SUT AROMALI %08 100
SUT AROMALI %08 1,00
KEK 35 G KEKSTRA %08 *070
KEK 35 G KEKSTRA %08 0,70
ALISVERIS POSETI %18 0,25
3X1,00
POPKEK MUZLU 6OG %08 3,00
DANKEK 40 GR %08 1,00
DANKEK 40 GR %08 x1.00
2X1,75
ETi KARAM GURME 50 G %08 *3.50
TOPKDV 1,96
TOPLAM 26,15
KREDi KARTI 26,15
Banka Kredi Karti.
Provizyon No527212
iyi sünler, yine bekleriz KASIYERI***A*** EKO NO:0001
ZNO0802 MYAB15024061''';

const ocrCanBolat = '''CANBOLATMARKET
NURDAG1.VD.1990376834 NO.45NURDAG1/G.ANTEP 03426712946
TESEKKORLER
SAAT1601 TAR1H14/02/2016
F15NO8881
TGIDA %8 *480.00
KDU *35,56
TOP *480.00
NAKIT 00080*
KASIYER:SATIS
ZNO0541 EKUNO:0002
RG11114742''';

void main() {
  group('Türkçe glif düzeltme (Go TestFixTurkishGlyphs ile aynı kurallar)', () {
    test(r'$ harf komşuluğunda ş/Ş olur; rakamdan önceki $ fiyat işaretidir', () {
      expect(fixTurkishGlyphs(r'FI$ NO'), 'FİŞ NO'.replaceAll('İ', 'I'));
      expect(fixTurkishGlyphs(r'KA$AR'), 'KAŞAR');
      expect(fixTurkishGlyphs(r'PE$IN'), 'PEŞIN');
      expect(fixTurkishGlyphs(r'a$k'), 'aşk');
      expect(fixTurkishGlyphs(r'%08 $3,95'), r'%08 $3,95');
      expect(fixTurkishGlyphs(r'A.$.'), 'A.Ş.');
      expect(fixTurkishGlyphs(r'US$ 1,00'), r'US$ 1,00');
      expect(fixTurkishGlyphs('Merhaba'), 'Merhaba');
      expect(fixTurkishGlyphs(fixTurkishGlyphs(r'KA$AR')), 'KAŞAR', reason: 'idempotent');
    });
  });

  group('yardımcılar', () {
    test('foldTR / containsWord / parseAmount / cleanItemName / KDV', () {
      expect(foldTR('İĞÜŞÖÇ ı'), 'igusoc i');
      expect(containsWord('abpx', 'bp'), isFalse);
      expect(containsWord('bp istasyonu', 'bp'), isTrue);
      expect(parseAmount('125,50'), 125.5);
      expect(parseAmount('1.250,50'), 1250.5);
      expect(parseAmount('12.345.678,90'), 12345678.9);
      const cases = {
        'MANTI 450 G MUTFAGIM      %08 *': 'MANTI 450 G MUTFAGIM',
        'MAKARNA SPAGETI500G 808': 'MAKARNA SPAGETI500G',
        'MEYVE NEKT.VISNE ILT 80%': 'MEYVE NEKT.VISNE ILT',
        'TGIDA %8 *': 'TGIDA',
        'SUT 1L TAM YAGLI': 'SUT 1L TAM YAGLI',
      };
      cases.forEach((i, o) => expect(cleanItemName(i), o, reason: i));
      for (final l in ['KDV *35,56', 'KDU *35,56', 'KDY *35,56', 'KOV *35,56', 'TOPKDV 1,96']) {
        expect(isKDVLine(l), isTrue, reason: l);
      }
      for (final l in ['KEK 35 G KEKSTRA 0,70', 'KUR 1,00', 'SUT 1L']) {
        expect(isKDVLine(l), isFalse, reason: l);
      }
    });

    test('"kart" yalnızca tam kelime: KARTON SÜT özet satırı sayılmaz', () {
      expect(nonItemLabel('KARTON SUT 12,50').strong || nonItemLabel('KARTON SUT 12,50').weak, isFalse);
      expect(nonItemLabel('KREDI KARTI 26,15').strong, isTrue);
    });
  });

  group('ayrıştırma', () {
    test('market fişi: tutar, tarih, işletme, kalemler, toplam uyuşmazlığı', () {
      const text = '''BİM BİRLEŞİK MAĞAZALAR A.Ş.
Atatürk Mah. No:5 İstanbul
TARİH: 12.05.2026  SAAT: 14:35
EKMEK        *5,00
SÜT          *32,50
TOPKDV       %1  1,20
TOPLAM       *1.250,75
KREDİ KARTI  1.250,75''';
      final r = parseReceiptText(text, now: _now);
      expect(r.amount, 1250.75);
      expect(r.date, '2026-05-12');
      expect(r.merchant, 'BİM BİRLEŞİK MAĞAZALAR A.Ş.');
      expect(r.needsManual, isFalse);
      expect(r.needsReview, isTrue);
      expect(r.itemsTotal, 37.5);
      expect(r.items.map((i) => (i.name, i.amount)), [('EKMEK', 5.0), ('SÜT', 32.5)]);
    });

    test('akaryakıt: tutar bir alt satırda; tarih tutar sanılmaz; geçersiz tarih elenir', () {
      expect(parseReceiptText('OPET\nİstasyon 123\n3.10.2026\nGENEL TOPLAM\n845,00', now: _now).amount, 845);
      expect(parseReceiptText('Market\n12.05.2026 14:35\nTOPLAM 20,00', now: _now).amount, 20);
      expect(parseReceiptText('X\n31.02.2026\nTOPLAM 10,00', now: _now).date, isNull);
    });

    test('okunamayan metin: needsManual', () {
      final r = parseReceiptText('okunamayan metin', now: _now);
      expect(r.needsManual, isTrue);
      expect(r.amount, isNull);
    });

    test('gerçek BIM Koltuk fişi: tarih etiketle yapışık, adet satırları kalem değil, PATITO x2 korunur', () {
      final r = parseReceiptText(ocrBimKoltuk, now: DateTime.utc(2026, 1, 1));
      expect(r.date, '2019-12-12');
      expect(r.amount, 26.15);
      expect(r.merchant, 'BIM BIRLESIK MAGAZALAR A.S');
      for (final i in r.items) {
        final n = i.name.toUpperCase();
        expect(n.startsWith('3X') || n.startsWith('2X') || n.contains('%'), isFalse, reason: i.name);
      }
      expect(r.items.where((i) => i.name.startsWith('PAT.CIPSI PATITO')).length, 2);
      // Çevrimdışı ayrıştırıcı ondalığı düşmüş iki tutarı ("*070", "100") kurtarmaz: 17 yerine 15 kalem ve
      // toplam uyuşmazlığı bayrağı (kullanıcı formda tamamlar).
      expect(r.items.length, 15);
      expect(r.needsReview, isTrue);
    });

    test('gerçek CanBolat fişi: TOP etiketi, KDU satırı kalem değil, yapışık tarih', () {
      final r = parseReceiptText(ocrCanBolat, now: DateTime.utc(2026, 1, 1));
      expect(r.amount, 480);
      expect(r.date, '2016-02-14');
      expect(r.merchant, 'CANBOLATMARKET');
      expect(r.items.any((i) => i.name.toUpperCase().contains('KDU')), isFalse);
      expect(r.needsReview, isFalse);
    });

    test('indirim satırı kalem toplamından düşülür; ParsedReceipt kategori Diğer + kontrol', () {
      final r = parseReceiptText('MARKET\n12.05.2026\nEKMEK 10,00\nSUT 20,00\nINDIRIM -5,00\nTOPLAM 25,00', now: _now);
      expect(r.discount, 5);
      expect(r.needsReview, isFalse);
      final p = r.toParsedReceipt(otherCategoryId: 11);
      expect(p.categoryId, 11);
      expect(p.categoryNeedsReview, isTrue);
      expect(p.discountTotal, 5);
      expect(p.items.every((i) => i.categoryId == 11 && i.categoryReview), isTrue);
    });

    test('ş düzeltmesi satır bölmede uygulanır', () {
      final lines = splitLines('FI\$ NO 0468\n\nKA\$AR 12,50');
      expect(lines, ['FIŞ NO 0468', 'KAŞAR 12,50']);
      expect(parseReceiptText('MARKET\n12.05.2026\nKA\$AR 12,50\nEKMEK 5,00\nTOPLAM 17,50', now: _now).items.first.name, 'KAŞAR');
    });
  });
}
