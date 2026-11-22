import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../budgets.dart';
import '../recurring.dart';
import '../theme.dart';
import '../widgets.dart';
import 'budgets_page.dart';
import 'receipt_detail_page.dart';
import 'recurring_page.dart';

/// Düzeye göre çubuk rengi: normal = vurgu, %80+ = sarı (uyarı), %100+ = kırmızı (kritik).
Color budgetLevelColor(FissioColors c, BudgetLevel level) => switch (level) {
  BudgetLevel.ok => c.accent,
  BudgetLevel.warning => c.warn,
  BudgetLevel.exceeded => c.danger,
};

/// Harcama/limit ilerleme çubuğu. [ratio] 1'i aşarsa çubuk dolu kalır, renk kırmızıdır.
class BudgetBar extends StatelessWidget {
  const BudgetBar({super.key, required this.ratio, required this.level, this.height = 8});
  final double ratio;
  final BudgetLevel level;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: 'Bütçe kullanımı',
      // Satırdaki yüzdeyle aynı (aşağı yuvarlama); küçük pay kayan nokta artığını (56,999…) yutar.
      value: '%${ratio.isNaN ? 0 : (ratio * 100 + 1e-6).floor()}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: c.surf2),
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: ratio.isNaN ? 0 : ratio.clamp(0.0, 1.0),
                  heightFactor: 1,
                  child: ColoredBox(key: const ValueKey('budget-fill'), color: budgetLevelColor(c, level)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bir kategorinin bütçe satırı: ad, harcanan / limit, yüzde ve ilerleme çubuğu.
class BudgetRow extends StatelessWidget {
  const BudgetRow({super.key, required this.progress, this.onTap, this.title});
  final BudgetProgress progress;
  final VoidCallback? onTap;

  /// Verilirse bütçedeki kategori adı yerine gösterilir (ör. adı bilinmeyen kategori).
  final String? title;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final level = progress.level;
    final pct = progress.percent;
    final note = switch (level) {
      BudgetLevel.ok => null,
      BudgetLevel.warning => 'Limitin %$kBudgetWarnPercent\'ine ulaştın',
      BudgetLevel.exceeded => 'Limit ${fmtMoney(-progress.remaining)} aşıldı',
    };
    final valueColor = level == BudgetLevel.ok ? c.mute : budgetLevelColor(c, level);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title ?? (progress.budget.isTotal ? 'Toplam aylık bütçe' : progress.budget.categoryName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: FissioText.body(c, size: 15, weight: FontWeight.w600),
                ),
              ),
              Text('%$pct', style: FissioText.body(c, size: 14, weight: FontWeight.w600, color: valueColor)),
            ],
          ),
          const SizedBox(height: 8),
          BudgetBar(ratio: progress.ratio, level: level),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  note ?? '${fmtMoney(progress.spent)} / ${fmtMoney(progress.budget.limit)}',
                  style: FissioText.body(c, size: 13, color: note == null ? c.mute : valueColor),
                ),
              ),
              if (note != null)
                Text(
                  '${fmtMoney(progress.spent)} / ${fmtMoney(progress.budget.limit)}',
                  style: FissioText.money(c, size: 13, weight: FontWeight.w400, color: c.mute),
                ),
            ],
          ),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// Özet ekranı: "Bütçeler" bölümü (aktif profilin bu ayki limit / harcama çubukları).
class BudgetsSection extends StatelessWidget {
  const BudgetsSection({super.key, this.app});

  /// Verilmezse global [appState].
  final AppState? app;

  @override
  Widget build(BuildContext context) {
    // Üst widget `const` verilebilir (Özet sayfası böyle); bu yüzden durumu burada kendimiz dinleriz.
    return ListenableBuilder(listenable: app ?? appState, builder: (context, _) => _content(context));
  }

  Widget _content(BuildContext context) {
    final c = context.c;
    final progress = (app ?? appState).budgetProgress;
    void manage() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BudgetsPage()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          'Bütçeler · bu ay',
          trailing: GestureDetector(
            key: const Key('budgets-manage'),
            onTap: manage,
            child: Text(
              progress.isEmpty ? 'Ekle' : 'Düzenle',
              style: FissioText.body(c, size: 14, weight: FontWeight.w600, color: c.accentInk),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (progress.isEmpty)
          InkWell(
            onTap: manage,
            borderRadius: BorderRadius.circular(kRadius),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: c.surf, borderRadius: BorderRadius.circular(kRadius)),
              child: Row(
                children: [
                  Icon(LucideIcons.gauge, size: 20, color: c.accentInk),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Toplam ve kategori başına aylık limit belirle; %80\'e ulaşınca uyarı alırsın.',
                      style: FissioText.body(c, size: 14, color: c.mute),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          GroupedCard(
            children: [for (final p in progress) BudgetRow(progress: p, onTap: manage)],
          ),
      ],
    );
  }
}

String daysLeftLabel(int d) => d < 0
    ? '${-d} gün gecikti'
    : d == 0
    ? 'Bugün'
    : d == 1
    ? 'Yarın'
    : '$d gün sonra';

/// Tekrarlayan bir giderin satırı: ad, kategori · ödeme günü / kalan gün, tutar.
class RecurringTile extends StatelessWidget {
  const RecurringTile({super.key, required this.item, required this.today, this.showDue = true});
  final RecurringItem item;
  final DateTime today;
  final bool showDue;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final days = item.daysUntil(today);
    final overdue = item.isOverdue(today);
    final soon = !overdue && !item.paidThisMonth && days >= 0 && days <= 3;
    // Gecikmiş = kırmızı (tehlike), ≤3 gün kala = sarı (uyarı); ödenmiş/uzak gün normal renkte.
    final dueStyle = overdue
        ? TextStyle(color: c.danger, fontWeight: FontWeight.w600)
        : soon
        ? TextStyle(color: c.warn, fontWeight: FontWeight.w600)
        : null;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReceiptDetailPage(id: item.lastExpenseId)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            IconTile(item.remind ? LucideIcons.bellRing : LucideIcons.repeat, size: 34, radius: 10),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FissioText.body(c, size: 15, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      style: FissioText.body(c, size: 13, color: c.mute),
                      children: [
                        if (item.isVariable) const TextSpan(text: 'Fatura · '),
                        if (item.paidThisMonth) ...[
                          TextSpan(
                            text: 'Bu ay ödendi',
                            style: TextStyle(color: c.accentInk, fontWeight: FontWeight.w600),
                          ),
                          TextSpan(text: ' · sonraki ${fmtDate(item.nextDue)}'),
                        ] else ...[
                          TextSpan(text: '${fmtDate(item.nextDue)} · '),
                          // Tümü listesinde de gecikme görünür (ödeme günü yerine "N gün gecikti").
                          TextSpan(
                            text: showDue || overdue ? daysLeftLabel(days) : 'ayın ${item.day}. günü',
                            style: dueStyle,
                          ),
                          if (!item.countsInTotal) const TextSpan(text: ' · toplama dahil değil'),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Sağ sütun en çok satırın ~%45'i: dar ekranda (320-360 px) uzun tutar/aralık başlığı ezmesin ve taşmasın;
            // sığmayan tutar küçülür (FittedBox), başlık zaten ellipsis ile kısalır.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .45),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      key: Key('recurring-amount-${item.lastExpenseId}'),
                      // Ödendi: gerçek tutar; değişken fatura: tahmini (≈); sabit: tutar.
                      item.paidThisMonth
                          ? fmtMoney(item.actualAmount)
                          : (item.isVariable ? '≈ ${fmtMoney(item.expected)}' : fmtMoney(item.expected)),
                      style: FissioText.money(c, size: 15),
                    ),
                  ),
                  if (item.paidThisMonth)
                    Text('Ödendi', key: const Key('paid-badge'), style: FissioText.body(c, size: 12, color: c.accentInk))
                  else if (item.hasRange)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        '${fmtMoney(item.minAmount)} – ${fmtMoney(item.maxAmount)}',
                        key: const Key('range-caption'),
                        style: FissioText.body(c, size: 12, color: c.mute),
                      ),
                    )
                  else if (item.isVariable)
                    Text('tahmini', style: FissioText.body(c, size: 12, color: c.mute)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Projeksiyonun dökümü: bu ay ödenen (gerçek) + kalan (beklenen) ve değişken faturalar yüzünden tahmini aralık.
class ProjectionBreakdown extends StatelessWidget {
  const ProjectionBreakdown({super.key, required this.proj});
  final RecurringProjection proj;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final style = FissioText.body(c, size: 13, color: c.mute);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Ödenen ${fmtMoney(proj.paidTotal)} · Kalan ${fmtMoney(proj.remainingTotal)}',
          key: const Key('fixed-projection-split'),
          style: style,
        ),
        if (proj.hasRange)
          Text(
            'Tahmini aralık ${fmtMoney(proj.minTotal)} – ${fmtMoney(proj.maxTotal)}',
            key: const Key('fixed-projection-range'),
            style: style,
          ),
      ],
    );
  }
}

/// Özet ekranı: "Aylık Sabit Gider Projeksiyonu" ve yaklaşan ödemeler.
class FixedExpensesSection extends StatelessWidget {
  const FixedExpensesSection({super.key, this.app, this.now});

  /// Verilmezse global [appState]; [now] testlerde "bugün"ü sabitler.
  final AppState? app;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: app ?? appState, builder: (context, _) => _content(context));
  }

  Widget _content(BuildContext context) {
    final c = context.c;
    final proj = (app ?? appState).recurring;
    final today = now ?? DateTime.now();
    // Yaklaşan (ödenmemiş) ödemeler + bu ay ödenmiş kalemler ("Ödendi" olarak, gerçek tutarla).
    final upcoming = [
      ...upcomingPaymentsOf(proj.items, today).where((i) => !i.paidThisMonth).take(3),
      ...proj.items.where((i) => i.paidThisMonth).take(3),
    ];
    void openAll() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecurringPage()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          'Sabit giderler',
          trailing: proj.items.isEmpty
              ? null
              : InkWell(
                  key: const Key('recurring-all'),
                  onTap: openAll,
                  borderRadius: BorderRadius.circular(8),
                  // Dokunma hedefi küçük bir metin değil: en az 44 px yüksekliğinde.
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        widthFactor: 1,
                        child: Text(
                          'Tümü',
                          style: FissioText.body(c, size: 14, weight: FontWeight.w600, color: c.accentInk),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 8),
        // Material (dekorlu Container değil): satırların InkWell dalgası kartın ARKASINDA kalıp görünmez olmasın.
        Material(
          key: const Key('fixed-projection'),
          color: c.surf,
          borderRadius: BorderRadius.circular(kRadius),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: proj.items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Fiş eklerken "Her ay tekrarlanır"ı açarak elektrik, su, internet, kira gibi sabit giderlerini '
                    'takip et ve ödeme hatırlatıcısı al.',
                    style: FissioText.body(c, size: 14, color: c.mute),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('AYLIK SABİT GİDER PROJEKSİYONU', style: FissioText.label(c)),
                    const SizedBox(height: 8),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        fmtMoney(proj.monthlyTotal),
                        key: const Key('fixed-projection-total'),
                        style: FissioText.money(c, size: 30, weight: FontWeight.w800, letterSpacing: -.8),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${proj.items.length} tekrarlayan gider'
                      '${proj.items.any((i) => !i.countsInTotal) ? ' · ${proj.items.where((i) => !i.countsInTotal).length} tanesi toplama dahil değil' : ''}',
                      style: FissioText.body(c, size: 13, color: c.mute),
                    ),
                    ProjectionBreakdown(proj: proj),
                    if (upcoming.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Divider(height: 1, thickness: 1, color: c.line),
                      for (var i = 0; i < upcoming.length; i++) ...[
                        if (i > 0) Divider(height: 1, thickness: 1, color: c.line),
                        RecurringTile(item: upcoming[i], today: today),
                      ],
                    ] else
                      const SizedBox(height: 10),
                  ],
                ),
          ),
        ),
      ],
    );
  }
}
