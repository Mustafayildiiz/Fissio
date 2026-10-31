import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'items_page.dart';
import 'scan_page.dart';

/// "Manuel" / "Tara" seçici (iki ekranda da aynı).
class ModeSwitch extends StatelessWidget {
  const ModeSwitch({super.key, required this.scanActive, required this.onChange});
  final bool scanActive;
  final ValueChanged<bool> onChange; // true = Tara

  @override
  Widget build(BuildContext context) {
    Widget tab(String label, IconData icon, bool active, VoidCallback onTap) =>
        Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: active ? AppColors.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 16, color: active ? Colors.white : AppColors.darkText),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: active ? Colors.white : AppColors.darkText,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: AppColors.light,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          tab('Manuel', Icons.edit, !scanActive, () => onChange(false)),
          const SizedBox(width: 6),
          tab('Tara', Icons.document_scanner_outlined, scanActive, () => onChange(true)),
        ],
      ),
    );
  }
}

class ReceiptFormPage extends StatefulWidget {
  const ReceiptFormPage({super.key, this.initial});
  final Expense? initial; // doluysa düzenleme

  @override
  State<ReceiptFormPage> createState() => _ReceiptFormPageState();
}

class _ReceiptFormPageState extends State<ReceiptFormPage> {
  late final ReceiptDraft _draft;
  late final TextEditingController _merchant;
  late final TextEditingController _note;

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    _draft = _editing ? ReceiptDraft.from(widget.initial!) : ReceiptDraft();
    _merchant = TextEditingController(text: _draft.merchant);
    _note = TextEditingController(text: _draft.note);
    if (appState.categories.isEmpty) appState.refresh();
  }

  @override
  void dispose() {
    _merchant.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _draft.date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d != null) setState(() => _draft.date = d);
  }

  void _next() {
    if (_draft.categoryId == null) {
      showMessage(context, 'Lütfen bir kategori seçin.');
      return;
    }
    _draft
      ..merchant = _merchant.text.trim()
      ..note = _note.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ItemsPage(draft: _draft)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            BackTitle(_editing ? 'Fişi Düzenle' : 'Fiş Oluştur', circle: true),
            if (!_editing)
              ModeSwitch(
                scanActive: false,
                onChange: (scan) {
                  if (scan) {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const ScanPage()),
                    );
                  }
                },
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (!_editing) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.light,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Fiş fotoğrafı',
                            style: TextStyle(color: AppColors.darkText, fontSize: 18),
                          ),
                          const SizedBox(height: 10),
                          InkWell(
                            onTap: () => showMessage(
                              context,
                              'Fotoğraf ile okuma bir sonraki fazda (Faz 5) eklenecek.',
                            ),
                            child: Container(
                              height: 120,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: AppColors.darkText, width: 1.4),
                              ),
                              child: const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  CircleAvatar(
                                    radius: 18,
                                    backgroundColor: Color(0xFFE2E8F0),
                                    child: Icon(Icons.photo_camera_outlined,
                                        size: 20, color: AppColors.darkText),
                                  ),
                                  SizedBox(height: 8),
                                  Text('Fotoğraf ekle',
                                      style: TextStyle(color: AppColors.darkText)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.light,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        TextField(
                          controller: _merchant,
                          style: const TextStyle(color: AppColors.darkText),
                          decoration: lightField('Marka', hint: 'Marka adı giriniz'),
                        ),
                        const SizedBox(height: 10),
                        ListenableBuilder(
                          listenable: appState,
                          builder: (_, _) => DropdownButtonFormField<int>(
                            initialValue: _draft.categoryId,
                            isExpanded: true,
                            dropdownColor: AppColors.light,
                            style: const TextStyle(
                              color: AppColors.darkText,
                              fontFamily: fontFamily,
                            ),
                            decoration: lightField('Kategori', hint: 'Kategori seçiniz'),
                            items: [
                              for (final c in appState.categories)
                                DropdownMenuItem(value: c.id, child: Text(c.name)),
                            ],
                            onChanged: (v) => setState(() => _draft.categoryId = v),
                          ),
                        ),
                        const SizedBox(height: 10),
                        InkWell(
                          onTap: _pickDate,
                          child: IgnorePointer(
                            child: TextField(
                              controller: TextEditingController(text: fmtDate(_draft.date)),
                              style: const TextStyle(color: AppColors.darkText),
                              decoration: lightField(
                                'Tarih',
                                suffix: const Icon(Icons.calendar_today,
                                    size: 18, color: AppColors.darkText),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _note,
                          maxLines: 2,
                          maxLength: 500,
                          style: const TextStyle(color: AppColors.darkText),
                          decoration:
                              lightField('Açıklama', hint: 'Açıklama giriniz').copyWith(counterText: ''),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Center(child: PrimaryButton(label: 'Ürün Ekle', onPressed: _next)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

