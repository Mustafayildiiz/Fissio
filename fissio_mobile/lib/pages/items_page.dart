import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';

class _Row {
  _Row(String name, double? amount)
      : name = TextEditingController(text: name),
        amount = TextEditingController(
          text: amount == null || amount == 0
              ? ''
              : amount.toStringAsFixed(2).replaceAll('.', ','),
        );
  final TextEditingController name;
  final TextEditingController amount;

  double get value =>
      double.tryParse(amount.text.trim().replaceAll(',', '.')) ?? 0;

  void dispose() {
    name.dispose();
    amount.dispose();
  }
}

class ItemsPage extends StatefulWidget {
  const ItemsPage({super.key, required this.draft});
  final ReceiptDraft draft;

  @override
  State<ItemsPage> createState() => _ItemsPageState();
}

class _ItemsPageState extends State<ItemsPage> {
  late final List<_Row> _rows;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _rows = widget.draft.items.map((i) => _Row(i.name, i.amount)).toList();
    if (_rows.isEmpty) _rows.add(_Row('', null));
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  double get _total => _rows.fold(0.0, (s, r) => s + r.value);

  Future<void> _save() async {
    final items = [
      for (final r in _rows)
        if (r.name.text.trim().isNotEmpty || r.value > 0)
          ExpenseItem(r.name.text.trim(), r.value),
    ];
    if (items.isEmpty || items.fold<double>(0, (s, i) => s + i.amount) <= 0) {
      showMessage(context, 'En az bir ürün ve tutar girin.');
      return;
    }
    widget.draft.items = items;
    setState(() => _busy = true);
    try {
      await appState.saveDraft(widget.draft);
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      showMessage(context, widget.draft.id == null ? 'Fiş kaydedildi.' : 'Fiş güncellendi.');
    } on ApiException catch (e) {
      // Ağ hatasında kuyruğa alınmaz; form ekranda kalır, kullanıcı tekrar dener.
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.draft.id != null;
    const dark = TextStyle(color: AppColors.darkText);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const BackTitle('Ürün Ekle'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.light,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Text('Toplam Tutar', style: dark.copyWith(fontSize: 13)),
                        const Spacer(),
                        Text(fmtMoney(_total), style: dark.copyWith(fontSize: 22)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.light,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                          child: Row(
                            children: [
                              Text('Ürün İsmi', style: dark.copyWith(fontSize: 13)),
                              const Spacer(),
                              Text('Tutar', style: dark.copyWith(fontSize: 13)),
                              const SizedBox(width: 40),
                            ],
                          ),
                        ),
                        for (var i = 0; i < _rows.length; i++)
                          Container(
                            decoration: const BoxDecoration(
                              border: Border(top: BorderSide(color: AppColors.darkText)),
                            ),
                            padding: const EdgeInsets.only(left: 14, right: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: TextField(
                                    controller: _rows[i].name,
                                    style: dark.copyWith(fontSize: 14),
                                    decoration: const InputDecoration(
                                      hintText: 'ürün adı',
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: TextField(
                                    controller: _rows[i].amount,
                                    onChanged: (_) => setState(() {}),
                                    textAlign: TextAlign.right,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    style: dark.copyWith(fontSize: 14),
                                    decoration: const InputDecoration(
                                      hintText: '0,00',
                                      suffixText: ' ₺',
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Ürünü sil',
                                  icon: const Icon(Icons.close, size: 18, color: AppColors.darkText),
                                  onPressed: () => setState(() {
                                    _rows.removeAt(i).dispose();
                                    if (_rows.isEmpty) _rows.add(_Row('', null));
                                  }),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  InkWell(
                    onTap: () => setState(() => _rows.add(_Row('', null))),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.secondaryText.withValues(alpha: .5)),
                        color: AppColors.card.withValues(alpha: .5),
                      ),
                      child: const Row(
                        children: [
                          CircleAvatar(
                            radius: 13,
                            backgroundColor: AppColors.accent,
                            child: Icon(Icons.add, size: 16, color: Colors.white),
                          ),
                          SizedBox(width: 10),
                          Text('Yeni ürün ekle', style: TextStyle(color: Colors.white, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Center(
                    child: PrimaryButton(
                      label: editing ? 'Fişi Güncelle' : 'Fiş Oluştur',
                      busy: _busy,
                      onPressed: _save,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

