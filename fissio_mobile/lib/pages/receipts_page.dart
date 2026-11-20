import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../dialogs.dart';
import '../models.dart';
import '../receipt_parser/normalize.dart' show foldTR;
import '../stats.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt_detail_page.dart';
import 'settings_page.dart';

enum _Sort {
  dateDesc('En yeni', 'Tarih (yeniden eskiye)'),
  dateAsc('En eski', 'Tarih (eskiden yeniye)'),
  amountDesc('En yüksek tutar', 'Tutar (çoktan aza)'),
  amountAsc('En düşük tutar', 'Tutar (azdan çoğa)');

  const _Sort(this.pill, this.sheet);
  final String pill;
  final String sheet;

  bool get byDate => this == dateDesc || this == dateAsc;
}

class ReceiptsPage extends StatefulWidget {
  const ReceiptsPage({super.key, required this.categoryFilter});
  final ValueNotifier<int?> categoryFilter;

  @override
  State<ReceiptsPage> createState() => _ReceiptsPageState();
}

class _ReceiptsPageState extends State<ReceiptsPage> {
  final _search = TextEditingController();
  _Sort _sort = _Sort.dateDesc;
  DateTimeRange? _range;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Expense> _visible(int? categoryId) {
    final q = foldTR(_search.text.trim());
    final list = appState.expenses.where((e) {
      if (categoryId != null && e.categoryId != categoryId) return false;
      if (q.isNotEmpty &&
          !foldTR(e.merchant).contains(q) &&
          !foldTR(e.categoryName).contains(q)) {
        return false;
      }
      if (_range != null) {
        final d = DateTime(e.date.year, e.date.month, e.date.day);
        if (d.isBefore(_range!.start) || d.isAfter(_range!.end)) return false;
      }
      return true;
    }).toList();
    switch (_sort) {
      case _Sort.dateDesc:
        list.sort((a, b) => b.date.compareTo(a.date));
      case _Sort.dateAsc:
        list.sort((a, b) => a.date.compareTo(b.date));
      case _Sort.amountDesc:
        list.sort((a, b) => b.amount.compareTo(a.amount));
      case _Sort.amountAsc:
        list.sort((a, b) => a.amount.compareTo(b.amount));
    }
    return list;
  }

  Future<void> _pickSort() async {
    final r = await showChoiceSheet<_Sort>(
      context,
      title: 'Sıralama',
      options: [for (final s in _Sort.values) (s, s.sheet)],
      selected: _sort,
    );
    if (r != null) setState(() => _sort = r);
  }

  Future<void> _pickCategory() async {
    final r = await showChoiceSheet<int>(
      context,
      title: 'Kategori',
      options: [
        (-1, 'Tüm kategoriler'),
        for (final cat in appState.categories) (cat.id, cat.name),
      ],
      selected: widget.categoryFilter.value ?? -1,
    );
    if (r != null) widget.categoryFilter.value = r == -1 ? null : r;
  }

  Future<void> _pickRange() async {
    if (_range != null) {
      final action = await showChoiceSheet<bool>(
        context,
        title: 'Tarih filtresi',
        options: const [(false, 'Aralığı değiştir'), (true, 'Filtreyi temizle')],
        selected: null,
      );
      if (action == null) return;
      if (action) {
        setState(() => _range = null);
        return;
      }
    }
    if (!mounted) return;
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: _range,
    );
    if (r != null) setState(() => _range = r);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LargeTitleHeader('Fişler', trailing: ProfileAvatar()),
        Container(
          height: 40,
          margin: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: c.surf2,
            borderRadius: BorderRadius.circular(kRadiusSm),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.search, size: 18, color: c.mute),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  cursorColor: c.accentInk,
                  style: FissioText.body(c),
                  decoration: InputDecoration(
                    hintText: 'Marka veya ürün ara',
                    hintStyle: FissioText.body(c, color: c.mute),
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (_search.text.isNotEmpty)
                GestureDetector(
                  onTap: () => setState(_search.clear),
                  child: Icon(LucideIcons.x, size: 16, color: c.mute),
                ),
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<int?>(
            valueListenable: widget.categoryFilter,
            builder: (context, catId, _) {
              final catName = catId == null
                  ? 'Kategori'
                  : appState.categories
                          .where((x) => x.id == catId)
                          .map((x) => x.name)
                          .firstOrNull ??
                      'Kategori';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      children: [
                        FilterPill(
                          label: _sort.pill,
                          icon: LucideIcons.arrowUpDown,
                          active: true,
                          onTap: _pickSort,
                        ),
                        const SizedBox(width: 8),
                        FilterPill(
                          label: catName,
                          dropdown: true,
                          active: catId != null,
                          onTap: _pickCategory,
                        ),
                        const SizedBox(width: 8),
                        FilterPill(
                          label: _range == null
                              ? 'Tarih'
                              : '${fmtDate(_range!.start)} - ${fmtDate(_range!.end)}',
                          dropdown: true,
                          active: _range != null,
                          onTap: _pickRange,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: appState,
                      builder: (context, _) => _list(catId),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _list(int? catId) {
    final c = context.c;
    final items = _visible(catId);
    final now = DateTime.now();

    void open(Expense e) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ReceiptDetailPage(id: e.id)),
        );

    final children = <Widget>[];
    if (_sort.byDate) {
      for (final g in groupByMonth(items)) {
        children.add(
          Container(
            margin: const EdgeInsets.only(top: 24),
            padding: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.rule, width: 2)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    g.title(now),
                    style: FissioText.title(c, size: 17).copyWith(letterSpacing: 0),
                  ),
                ),
                Text(
                  fmtMoney(g.total),
                  style: FissioText.money(c, size: 14, color: c.mute),
                ),
              ],
            ),
          ),
        );
        for (final e in g.items) {
          children.add(ReceiptTile(expense: e, onTap: () => open(e)));
        }
      }
    } else {
      children.add(const SizedBox(height: 12));
      for (final e in items) {
        children.add(ReceiptTile(expense: e, onTap: () => open(e)));
      }
    }

    return RefreshIndicator(
      onRefresh: appState.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(20, 0, 20, FissioTabBar.heightOf(context) + 16),
        children: [
          if (appState.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ErrorBanner(appState.error!, onRetry: appState.refresh),
            ),
          if (items.isEmpty && !appState.loading && appState.error == null)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: Text(
                  'Henüz fiş yok.\nAlttaki + ile ekleyin.',
                  textAlign: TextAlign.center,
                  style: FissioText.body(c, color: c.mute).copyWith(height: 1.4),
                ),
              ),
            ),
          ...children,
        ],
      ),
    );
  }
}
