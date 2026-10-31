import 'package:fissio_mobile/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('para biçimi', () {
    expect(fmtMoney(1250.5), '1.250,50 ₺');
    expect(fmtMoney(0), '0,00 ₺');
    expect(fmtMoney(1234567.89), '1.234.567,89 ₺');
  });

  test('tarih biçimi', () {
    expect(fmtDate(DateTime(2026, 5, 3)), '03.05.2026');
    expect(isoDate(DateTime(2026, 5, 3)), '2026-05-03');
  });
}
