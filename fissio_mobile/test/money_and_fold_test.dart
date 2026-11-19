import 'package:fissio_mobile/budgets.dart' show parseMoneyInput;
import 'package:fissio_mobile/data/data_transfer.dart';
import 'package:fissio_mobile/money.dart';
import 'package:fissio_mobile/receipt_parser/normalize.dart' show foldTR;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tek parseMoney: tüm girdi yolları aynı sonucu verir', () {
    const cases = {
      '12,50': 12.5,
      '12.50': 12.5,
      '1.234,50': 1234.5,
      '1,234.50': 1234.5, // önceden budgets yolunda 1.2345 çıkıyordu
      '1.234': 1234.0,
      '8000': 8000.0,
      '12,50 ₺': 12.5,
      '3000 TL': 3000.0,
    };
    cases.forEach((input, want) {
      expect(parseMoney(input), want, reason: input);
      expect(parseMoneyInput(input), want, reason: 'budgets: $input');
      expect(parseAmount(input), want, reason: 'data_transfer: $input');
    });
    for (final bad in ['', 'abc', '₺']) {
      expect(parseMoney(bad), isNull, reason: bad);
    }
  });

  test('Türkçe büyük İ/küçük ı: arama ve ad eşleşmesi foldTR ile yapılır', () {
    expect(foldTR('MİGROS ŞİŞLİ'), foldTR('migros şişli'));
    expect(foldTR('İÇECEK').contains(foldTR('icecek')), isTrue);
    // Aksan duyarsız: 'çay' araması 'ÇAY' / 'Çay' fişlerini bulur (toLowerCase bunu yapmaz).
    expect(foldTR('ÇAY'), foldTR('çay'));
    expect('ÇAY'.toLowerCase().contains('cay'), isFalse);
  });

  test('CSV başlığı büyük harf / Türkçe yazımla da tanınır; parmak izi İ içeren adlarda kararlı', () {
    final csv = 'TARİH;İŞYERİ;TOPLAM\n12.05.2026;MİGROS;45,50\n';
    final data = parseBackup(csv);
    expect(data.profiles.single.expenses.single.merchant, 'MİGROS');
    expect(data.profiles.single.expenses.single.amount, 45.5);
    final a = fingerprint('Kişisel', DateTime(2026, 5, 12), 'MİGROS', 45.5, const []);
    final b = fingerprint('Kişisel', DateTime(2026, 5, 12), 'Migros', 45.5, const []);
    expect(a, b); // İ→i: büyük/küçük harf ve İ yazımı aynı fişi verir (ASCII parmak izleri değişmedi)
    expect(fingerprint('Kişisel', DateTime(2026, 5, 12), 'MİGROS', 45.5, const []),
        fingerprint('Kişisel', DateTime(2026, 5, 12), 'miGROS', 45.5, const []));
  });
}
