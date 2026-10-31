import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt_detail_page.dart';
import 'receipt_form_page.dart';
import 'scan_page.dart';

enum _Sort { dateDesc, dateAsc, amountDesc, amountAsc }

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
    final q = _search.text.trim().toLowerCase();
    final list = appState.expenses.where((e) {
      if (categoryId != null && e.categoryId != categoryId) return false;
      if (q.isNotEmpty &&
          !e.merchant.toLowerCase().contains(q) &&
          !e.categoryName.toLowerCase().contains(q)) {
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
    const labels = {
      _Sort.dateDesc: 'Tarih (yeniden eskiye)',
      _Sort.dateAsc: 'Tarih (eskiden yeniye)',
      _Sort.amountDesc: 'Tutar (çoktan aza)',
      _Sort.amountAsc: 'Tutar (azdan çoğa)',
    };
    final r = await showModalBottomSheet<_Sort>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in labels.entries)
              ListTile(
                title: Text(e.value),
                trailing: e.key == _sort
                    ? const Icon(Icons.check, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(context, e.key),
              ),
          ],
        ),
      ),
    );
    if (r != null) setState(() => _sort = r);
  }

  Future<void> _pickCategory() async {
    final r = await showModalBottomSheet<int>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('Tüm kategoriler'),
              onTap: () => Navigator.pop(context, -1),
            ),
            for (final c in appState.categories)
              ListTile(
                title: Text(c.name),
                trailing: widget.categoryFilter.value == c.id
                    ? const Icon(Icons.check, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(context, c.id),
              ),
          ],
        ),
      ),
    );
    if (r != null) widget.categoryFilter.value = r == -1 ? null : r;
  }

  Future<void> _pickRange() async {
    if (_range != null) {
      final clear = await showDialog<bool>(
        context: context,
        builder: (_) => SimpleDialog(
          title: const Text('Tarih filtresi'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Aralığı değiştir'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Filtreyi temizle'),
            ),
          ],
        ),
      );
      if (clear == null) return;
      if (clear) {
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
    return Stack(
      children: [
        Column(
          children: [
            const FissioHeader(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, color: AppColors.secondaryText),
                  hintText: 'Marka veya kategori ara',
                  hintStyle: const TextStyle(color: Color(0xFF94A3B8)),
                  filled: true,
                  fillColor: AppColors.card,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<int?>(
              valueListenable: widget.categoryFilter,
              builder: (context, catId, _) {
                final catName = catId == null
                    ? 'Kategori'
                    : appState.categories
                        .where((c) => c.id == catId)
                        .map((c) => c.name)
                        .firstOrNull ?? 'Kategori';
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          _FilterChip('sıralama', false, _pickSort),
                          const SizedBox(width: 8),
                          _FilterChip(catName, catId != null, _pickCategory),
                          const SizedBox(width: 8),
                          _FilterChip(
                            _range == null
                                ? 'Tarih'
                                : '${fmtDate(_range!.start)} - ${fmtDate(_range!.end)}',
                            _range != null,
                            _pickRange,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
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
          ],
        ),
        Positioned(
          right: 16,
          bottom: 12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FloatingActionButton(
                heroTag: 'scan',
                tooltip: 'Fiş tara',
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: const CircleBorder(),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ScanPage()),
                ),
                child: const Icon(Icons.photo_camera),
              ),
              const SizedBox(height: 10),
              FloatingActionButton(
                heroTag: 'add',
                tooltip: 'Manuel fiş ekle',
                backgroundColor: AppColors.secondaryText,
                foregroundColor: AppColors.darkText,
                shape: const CircleBorder(),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ReceiptFormPage()),
                ),
                child: const Icon(Icons.add),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _list(int? catId) {
    final items = _visible(catId);
    return RefreshIndicator(
      onRefresh: appState.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 150),
        children: [
          if (appState.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ErrorBanner(appState.error!, onRetry: appState.refresh),
            ),
          if (items.isEmpty && !appState.loading && appState.error == null)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(
                child: Text(
                  'Henüz fiş yok.\nSağ alttaki + ile ekleyin.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.secondaryText),
                ),
              ),
            ),
          for (final e in items)
            ReceiptTile(
              expense: e,
              onView: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ReceiptDetailPage(id: e.id)),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip(this.label, this.active, this.onTap);
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: active ? AppColors.accent : AppColors.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

