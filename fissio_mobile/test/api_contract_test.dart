import 'dart:convert';

import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_backend.dart';

// İstemci ↔ Go sunucusu JSON sözleşmesinin kırılgan kenarları: sayısal alanlar int/float fark etmeden okunur,
// hız sınırı süresi gövdede yoksa `Retry-After` başlığından alınır.

ApiClient _api(http.Client c) => ApiClient(
      client: c,
      device: FakeDevice(),
      authBase: 'http://fake-auth',
      expenseBase: 'http://fake-expense',
    );

void main() {
  test('429: gövdede retry_after yoksa Retry-After başlığı okunur', () async {
    final api = _api(MockClient((_) async => http.Response(
          jsonEncode({'error': 'too many requests', 'code': 'rate_limited'}),
          429,
          headers: {'content-type': 'application/json', 'retry-after': '42'},
        )));
    await expectLater(
      api.categories(),
      throwsA(isA<ApiException>().having((e) => e.retryAfter, 'retryAfter', 42).having((e) => e.status, 'status', 429)),
    );
  });

  test('gövdedeki retry_after başlığa tercih edilir; ikisi de yoksa null', () async {
    final both = _api(MockClient((_) async => http.Response(
          jsonEncode({'error': 'wait', 'code': 'otp_cooldown', 'retry_after': 7}),
          429,
          headers: {'content-type': 'application/json', 'retry-after': '60'},
        )));
    await expectLater(both.categories(), throwsA(isA<ApiException>().having((e) => e.retryAfter, 'retryAfter', 7)));

    final none = _api(MockClient((_) async => http.Response(
          jsonEncode({'error': 'auth unavailable', 'code': 'auth_unavailable'}),
          503,
          headers: {'content-type': 'application/json'},
        )));
    await expectLater(none.categories(), throwsA(isA<ApiException>().having((e) => e.retryAfter, 'retryAfter', isNull)));
  });

  test('sayısal kimlikler float olarak gelse de (12.0) ayrıştırılır', () {
    expect(Category.fromJson({'id': 3.0, 'name': 'Market'}).id, 3);
    final e = Expense.fromJson({
      'id': 12.0,
      'merchant': 'BIM',
      'amount': 10,
      'date': '2026-11-20',
      'category_id': 1,
    });
    expect(e.id, 12);
    expect(ParsedReceipt.fromJson({'category_id': 2.0}).categoryId, 2);
    expect(ParsedReceipt.fromJson({}).categoryId, 0);
  });
}
