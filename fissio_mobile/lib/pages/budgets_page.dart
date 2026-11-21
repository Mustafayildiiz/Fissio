import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../budgets.dart';
import '../dialogs.dart';
import '../models.dart' show kTotalBudgetCategoryId;
import '../theme.dart';
import '../widgets.dart';
import 'budget_widgets.dart';

/// Aktif profil için kategori bazlı aylık bütçe limitleri: bir kategoriye dokunup limit gir (boş bırakmak
/// limiti kaldırır). Harcama limitin %80'ine ulaşınca çubuk sarı, aşınca kırmızı olur ve bildirim gelir.
class BudgetsPage extends StatelessWidget {
  const BudgetsPage({super.key});

  Future<void> _edit(BuildContext context, int categoryId, String name, double? current) async {
    final raw = await showTextPrompt(
      context,
      title: '$name · aylık limit',
      confirmLabel: 'Kaydet',
      initial: current == null ? '' : current.toStringAsFixed(2).replaceAll('.', ','),
      hint: 'Örn. 8.000',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    if (raw == null || !context.mounted) return;
    try {
      if (raw.isEmpty) {
        await appState.removeBudget(categoryId);
        return;
      }
      final v = parseMoneyInput(raw);
      if (v == null || v < 0.01 || v >= 1e9) {
        showMessage(context, 'Geçerli bir tutar girin.');
        return;
      }
      final first = appState.budgets.isEmpty;
      await appState.setBudget(categoryId, (v * 100).round() / 100);
      // İlk limitte bildirim izni istenir (eşik uyarıları için).
      if (first) await appState.notifier.requestPermission();
    } on ApiException catch (e) {
      if (context.mounted) showError(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            final progress = {for (final p in appState.budgetProgress) p.budget.categoryId: p};
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const NavBackBar(label: 'Özet'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text('Bütçe limitleri', style: FissioText.title(c)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    '${appState.profileName ?? 'Profil'} için her ay geçerli. Harcama limitin %$kBudgetWarnPercent\'ine '
                    'ulaşınca çubuk sarı, aşınca kırmızı olur ve bildirim alırsın.',
                    style: FissioText.body(c, size: 14, color: c.mute).copyWith(height: 1.4),
                  ),
                ),
                const Rule2(margin: EdgeInsets.fromLTRB(20, 16, 20, 12)),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                    children: [
                      // Profilin TOPLAM aylık bütçesi: tüm kategorilerin o ayki toplamına karşı.
                      const SectionLabel('Toplam aylık bütçe'),
                      const SizedBox(height: 8),
                      GroupedCard(
                        children: [
                          if (progress[kTotalBudgetCategoryId] case final p?)
                            BudgetRow(
                              key: const ValueKey('budget-total'),
                              progress: p,
                              onTap: () => _edit(context, kTotalBudgetCategoryId, 'Toplam aylık bütçe', p.budget.limit),
                            )
                          else
                            ListRow(
                              key: const ValueKey('budget-total'),
                              title: 'Toplam aylık bütçe',
                              subtitle: 'Bu ay tüm kategoriler toplamında geçmek istemediğin tutar',
                              onTap: () => _edit(context, kTotalBudgetCategoryId, 'Toplam aylık bütçe', null),
                              chevron: true,
                              trailing: Text('Limit yok', style: FissioText.body(c, size: 14, color: c.mute)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      const SectionLabel('Kategori limitleri'),
                      const SizedBox(height: 8),
                      GroupedCard(
                        children: [
                          for (final cat in appState.categories)
                            if (progress[cat.id] case final p?)
                              BudgetRow(
                                key: ValueKey('budget-${cat.id}'),
                                progress: p,
                                onTap: () => _edit(context, cat.id, cat.name, p.budget.limit),
                              )
                            else
                              ListRow(
                                key: ValueKey('budget-${cat.id}'),
                                title: cat.name,
                                onTap: () => _edit(context, cat.id, cat.name, null),
                                chevron: true,
                                trailing: Text('Limit yok', style: FissioText.body(c, size: 14, color: c.mute)),
                              ),
                        ],
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
}
