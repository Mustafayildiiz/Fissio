import 'package:flutter/material.dart';

import '../app_state.dart';
import '../stats.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt_detail_page.dart';
import 'settings_page.dart';

/// "Özet": dönem seçici, toplam harcama, kategori dağılımı ve en yüksek fiş.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onOpenCategory, this.onOpenAll});

  /// Kategori satırına dokunulunca (kategori kimliğiyle) Fişler sekmesini açar.
  final ValueChanged<int> onOpenCategory;

  /// "Tümü" bağlantısı: filtresiz Fişler sekmesi.
  final VoidCallback? onOpenAll;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  HomePeriod _period = HomePeriod.month;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final stats = computeHomeStats(appState.expenses, _period);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LargeTitleHeader('Özet', trailing: ProfileAvatar()),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: SegmentedControl<HomePeriod>(
                value: _period,
                fontSize: 13,
                onChanged: (p) => setState(() => _period = p),
                items: [for (final p in HomePeriod.values) SegmentItem(p, p.label)],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: appState.refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    20,
                    22,
                    20,
                    FissioTabBar.heightOf(context) + 16,
                  ),
                  children: [
                    if (appState.error != null) ...[
                      ErrorBanner(appState.error!, onRetry: appState.refresh),
                      const SizedBox(height: 16),
                    ],
                    _TotalBlock(stats: stats, period: _period),
                    const Rule2(margin: EdgeInsets.symmetric(vertical: 20)),
                    SectionLabel(
                      'Kategoriler',
                      trailing: widget.onOpenAll == null
                          ? null
                          : GestureDetector(
                              onTap: widget.onOpenAll,
                              child: Text(
                                'Tümü',
                                style: FissioText.body(
                                  c,
                                  size: 14,
                                  weight: FontWeight.w600,
                                  color: c.accentInk,
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(height: 8),
                    _CategoriesCard(
                      stats: stats,
                      onOpenCategory: widget.onOpenCategory,
                    ),
                    const SizedBox(height: 22),
                    const SectionLabel('En yüksek fiş'),
                    const SizedBox(height: 8),
                    if (stats.highest == null)
                      const _EmptyCard()
                    else
                      ReceiptTile(
                        card: true,
                        expense: stats.highest!,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ReceiptDetailPage(id: stats.highest!.id),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TotalBlock extends StatelessWidget {
  const _TotalBlock({required this.stats, required this.period});
  final HomeStats stats;
  final HomePeriod period;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final pct = stats.changePct;
    final maxBucket = stats.buckets.fold<double>(0, (m, v) => v > m ? v : m);
    final sub = FissioText.body(c, size: 14, color: c.mute).copyWith(height: 1.3);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('TOPLAM HARCAMA', style: FissioText.label(c)),
              const SizedBox(height: 8),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  fmtMoney(stats.total),
                  maxLines: 1,
                  style: FissioText.money(
                    c,
                    size: 40,
                    weight: FontWeight.w800,
                    letterSpacing: -1.2,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(
                  style: sub,
                  children: [
                    TextSpan(text: '${stats.count} fiş'),
                    if (pct != null) ...[
                      const TextSpan(text: ' · '),
                      TextSpan(
                        text: fmtChange(pct),
                        style: TextStyle(
                          color: c.accentInk,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(text: ' ${period.compareLabel} göre'),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          height: 64,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < stats.buckets.length; i++) ...[
                if (i > 0) const SizedBox(width: 5),
                Container(
                  width: 10,
                  height: maxBucket <= 0
                      ? 6
                      : (64 * stats.buckets[i] / maxBucket).clamp(6, 64).toDouble(),
                  decoration: BoxDecoration(
                    color: i == stats.buckets.length - 1 && maxBucket > 0
                        ? c.accent
                        : c.surf2,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoriesCard extends StatelessWidget {
  const _CategoriesCard({required this.stats, required this.onOpenCategory});
  final HomeStats stats;
  final ValueChanged<int> onOpenCategory;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cats = stats.categories;
    if (cats.isEmpty) return const _EmptyCard();
    final colors = [c.accent, c.ink, c.mute];
    final top = cats.take(3).toList();
    final restShare = cats.skip(3).fold<double>(0, (s, e) => s + e.share);

    int flex(double share) => (share * 1000).round().clamp(1, 1000);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      decoration: BoxDecoration(
        color: c.surf,
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(kRadiusSm),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  for (var i = 0; i < top.length; i++) ...[
                    if (i > 0) const SizedBox(width: 3),
                    Expanded(
                      flex: flex(top[i].share),
                      child: ColoredBox(color: colors[i], child: const SizedBox.expand()),
                    ),
                  ],
                  if (restShare > 0) ...[
                    const SizedBox(width: 3),
                    Expanded(
                      flex: flex(restShare),
                      child: ColoredBox(color: c.seg4, child: const SizedBox.expand()),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < top.length; i++)
            InkWell(
              onTap: () => onOpenCategory(top[i].id),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  border: i < top.length - 1
                      ? Border(bottom: BorderSide(color: c.line))
                      : null,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: colors[i]),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        top[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FissioText.body(c, size: 15, weight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '%${(top[i].share * 100).round()}',
                      style: FissioText.body(c, size: 15, color: c.mute),
                    ),
                    SizedBox(
                      width: 96,
                      child: Text(
                        fmtMoney(top[i].total),
                        textAlign: TextAlign.right,
                        style: FissioText.money(c, size: 15),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surf,
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Text(
        appState.loading ? 'Yükleniyor...' : 'Bu dönemde fiş yok.',
        style: FissioText.body(c, size: 14, color: c.mute),
      ),
    );
  }
}
