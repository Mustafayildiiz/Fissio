import 'package:flutter/material.dart';

import '../app_state.dart';
import '../recurring.dart';
import '../theme.dart';
import '../widgets.dart';
import 'budget_widgets.dart';

/// Tekrarlayan giderler: aylık sabit gider projeksiyonu, yaklaşan ödemeler ve tüm seriler.
class RecurringPage extends StatelessWidget {
  const RecurringPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            final proj = appState.recurring;
            final today = DateTime.now();
            final upcoming = upcomingPaymentsOf(proj.items, today);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const NavBackBar(label: 'Özet'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text('Sabit giderler', style: FissioText.title(c)),
                ),
                const Rule2(margin: EdgeInsets.fromLTRB(20, 16, 20, 16)),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                    children: [
                      Text('AYLIK SABİT GİDER PROJEKSİYONU', style: FissioText.label(c)),
                      const SizedBox(height: 8),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          fmtMoney(proj.monthlyTotal),
                          style: FissioText.money(c, size: 40, weight: FontWeight.w800, letterSpacing: -1.2),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${proj.items.length} tekrarlayan gider · her seri bir kez sayılır: ödenenler gerçek tutarla, '
                        'kalanlar beklenen tutarla (değişken faturalar son 3 ayın ortalamasıyla).',
                        style: FissioText.body(c, size: 14, color: c.mute),
                      ),
                      const SizedBox(height: 4),
                      ProjectionBreakdown(proj: proj),
                      const Rule2(margin: EdgeInsets.symmetric(vertical: 20)),
                      const SectionLabel('Yaklaşan ödemeler · 30 gün'),
                      const SizedBox(height: 8),
                      if (upcoming.isEmpty)
                        _empty(c, 'Önümüzdeki 30 günde ödeme yok.')
                      else
                        GroupedCard(children: [for (final i in upcoming) RecurringTile(item: i, today: today)]),
                      const SizedBox(height: 22),
                      const SectionLabel('Tüm tekrarlayan giderler'),
                      const SizedBox(height: 8),
                      if (proj.items.isEmpty)
                        _empty(c, 'Henüz tekrarlayan gider yok. Fiş eklerken "Her ay tekrarlanır"ı aç.')
                      else
                        GroupedCard(
                          children: [for (final i in proj.items) RecurringTile(item: i, today: today, showDue: false)],
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _empty(FissioColors c, String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: c.surf, borderRadius: BorderRadius.circular(kRadius)),
    child: Text(text, style: FissioText.body(c, size: 14, color: c.mute)),
  );
}
