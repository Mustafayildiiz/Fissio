import 'dart:convert';
import 'dart:io';

import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/recurring.dart';
import 'package:flutter_test/flutter_test.dart';

/// `testdata/recurring_series.json`: Go `buildRecurring` ile aynı vektörler (takvim ayı penceresi, gelecek aya tarihli
/// fiş yok sayılır, 3 ay sessiz seri biter, gecikmiş bayrağı).
void main() {
  final data = jsonDecode(File('../testdata/recurring_series.json').readAsStringSync()) as Map<String, dynamic>;
  final cases = (data['cases'] as List).cast<Map<String, dynamic>>();

  test('yeterli vektör var', () => expect(cases.length, greaterThanOrEqualTo(6)));

  for (final c in cases) {
    test(c['name'] as String, () {
      final today = DateTime.parse(c['today'] as String);
      final rows = <Expense>[];
      var id = 0;
      for (final r in (c['rows'] as List).cast<Map<String, dynamic>>()) {
        id++;
        rows.add(
          Expense(
            id: id,
            merchant: r['merchant'] as String,
            amount: (r['amount'] as num).toDouble(),
            date: DateTime.parse(r['date'] as String),
            categoryId: r['category_id'] as int,
            categoryName: 'x',
            note: '',
            items: const [],
            clientUid: 'u$id',
            profileUid: 'p1',
            recurringDay: r['day'] as int,
            recurringRemind: true,
            recurringKind: r['kind'] == 'variable' ? RecurringKind.variable : RecurringKind.fixed,
            recurringEstimate: (r['estimate'] as num).toDouble(),
          ),
        );
      }
      final proj = buildRecurring(rows, today);
      final want = (c['expect'] as Map<String, dynamic>);
      final series = (want['series'] as List).cast<Map<String, dynamic>>();
      expect(proj.items.length, series.length);
      expect(proj.monthlyTotal, (want['monthly_total'] as num).toDouble());
      for (var i = 0; i < series.length; i++) {
        final w = series[i];
        final g = proj.items[i];
        expect(g.merchant, w['merchant']);
        expect(g.expected, (w['expected'] as num).toDouble());
        expect(g.minAmount, (w['min'] as num).toDouble());
        expect(g.maxAmount, (w['max'] as num).toDouble());
        expect(g.historyCount, w['history']);
        expect(g.paidThisMonth, w['paid']);
        expect(g.isOverdue(today), w['overdue']);
        expect(g.nextDue.toIso8601String().substring(0, 10), w['next_due']);
        expect(g.amount, (w['amount'] as num).toDouble());
        expect(g.countsInTotal, w['counts_in_total'] ?? true, reason: 'toplama dahil mi (vektörde yoksa true)');
      }
    });
  }
}
