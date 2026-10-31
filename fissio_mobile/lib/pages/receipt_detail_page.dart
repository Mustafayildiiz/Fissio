import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt_form_page.dart';

/// Üst ve alt kenarı fiş kağıdı gibi tırtıklı keser.
class _ZigZagClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    const tooth = 10.0;
    final n = (size.width / tooth).floor();
    final w = size.width / n;
    final p = Path()..moveTo(0, 0);
    for (var i = 0; i < n; i++) {
      p.lineTo(w * i + w / 2, tooth * .7);
      p.lineTo(w * (i + 1), 0);
    }
    p.lineTo(size.width, size.height);
    for (var i = n; i > 0; i--) {
      p.lineTo(w * i - w / 2, size.height - tooth * .7);
      p.lineTo(w * (i - 1), size.height);
    }
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class ReceiptDetailPage extends StatelessWidget {
  const ReceiptDetailPage({super.key, required this.id});
  final int id;

  Future<void> _delete(BuildContext context, Expense e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Fişi sil'),
        content: const Text('Bu fiş kalıcı olarak silinecek.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sil', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await appState.deleteExpense(e.id);
      if (context.mounted) Navigator.of(context).pop();
    } on ApiException catch (err) {
      if (context.mounted) showMessage(context, err.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final e = appState.expenses.where((x) => x.id == id).firstOrNull;
        if (e == null) {
          // Silindi veya bulunamadı.
          return Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  const BackTitle('Fiş'),
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Fiş bulunamadı.', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                BackTitle(
                  'Fiş',
                  trailing: PrimaryButton(
                    label: 'Düzenle',
                    compact: true,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ReceiptFormPage(initial: e)),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      ClipPath(
                        clipper: _ZigZagClipper(),
                        child: Container(
                          color: AppColors.light,
                          padding: const EdgeInsets.fromLTRB(16, 26, 16, 28),
                          child: _Paper(e),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton.icon(
                          onPressed: () => _delete(context, e),
                          icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                          label: const Text(
                            'Fişi sil',
                            style: TextStyle(color: AppColors.danger),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Paper extends StatelessWidget {
  const _Paper(this.e);
  final Expense e;

  @override
  Widget build(BuildContext context) {
    const dark = TextStyle(color: AppColors.darkText);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(width: 36),
            Expanded(
              child: Column(
                children: [
                  Text(
                    e.merchant.isEmpty ? 'Marka yok' : e.merchant,
                    textAlign: TextAlign.center,
                    style: dark.copyWith(fontSize: 26),
                  ),
                  Text(e.categoryName, style: dark.copyWith(fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.photo_camera, color: AppColors.darkText, size: 28),
            const SizedBox(width: 8),
          ],
        ),
        const SizedBox(height: 12),
        Text('Tarih : ${fmtDate(e.date)}', style: dark.copyWith(fontSize: 16)),
        const Divider(color: AppColors.darkText, thickness: 1.2, height: 18),
        if (e.items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text('Toplam kalem :', style: dark.copyWith(fontSize: 15)),
                ),
                Text(fmtMoney(e.amount), style: dark.copyWith(fontSize: 15)),
              ],
            ),
          ),
        for (final it in e.items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${it.name.isEmpty ? 'ürün' : it.name} :',
                    overflow: TextOverflow.ellipsis,
                    style: dark.copyWith(fontSize: 15),
                  ),
                ),
                Text(fmtMoney(it.amount), style: dark.copyWith(fontSize: 15)),
              ],
            ),
          ),
        const Divider(color: AppColors.darkText, thickness: 1.2, height: 18),
        Row(
          children: [
            Text('Toplam:', style: dark.copyWith(fontSize: 20)),
            const Spacer(),
            Text(fmtMoney(e.amount), style: dark.copyWith(fontSize: 22)),
          ],
        ),
        if (e.note.isNotEmpty) ...[
          const SizedBox(height: 12),
          Center(child: Text('Açıklama', style: dark.copyWith(fontSize: 18))),
          const SizedBox(height: 4),
          Text(e.note, style: dark.copyWith(fontSize: 13)),
        ],
      ],
    );
  }
}

