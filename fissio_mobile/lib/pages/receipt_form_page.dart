import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../dialogs.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'photo_picker.dart';
import 'scan_page.dart';

/// "Manuel" / "Tara" seçici (iki ekranda da aynı).
class ModeSwitch extends StatelessWidget {
  const ModeSwitch({
    super.key,
    required this.scanActive,
    required this.onChange,
  });
  final bool scanActive;
  final ValueChanged<bool> onChange; // true = Tara

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: SegmentedControl<bool>(
        value: scanActive,
        onChanged: onChange,
        items: const [
          SegmentItem(false, 'Manuel', icon: LucideIcons.pencil),
          SegmentItem(true, 'Tara', icon: LucideIcons.scan),
        ],
      ),
    );
  }
}

/// Ürün satırı için düzenleme denetleyicileri.
class _Row {
  _Row(
    String name,
    double? amount, {
    this.categoryId,
    this.suggestedCategoryId,
    this.review = false,
  })  : name = TextEditingController(text: name),
        amount = TextEditingController(
          text: amount == null || amount == 0
              ? ''
              : amount.toStringAsFixed(2).replaceAll('.', ','),
        );
  final TextEditingController name;
  final TextEditingController amount;

  /// Kalem kategorisi (otomatik atanır; kullanıcı değiştirebilir), taramada önerilen kategori ve
  /// "güvenilir değil" bayrağı.
  int? categoryId;
  final int? suggestedCategoryId;
  bool review;

  double get value {
    final s = amount.text.trim().replaceAll(' ', '');
    if (s.isEmpty) return 0;
    if (s.contains(',')) {
      return double.tryParse(s.replaceAll('.', '').replaceAll(',', '.')) ?? 0;
    }
    return double.tryParse(s) ?? 0;
  }

  void dispose() {
    name.dispose();
    amount.dispose();
  }
}

/// Fiş oluştur / düzenle: bilgiler ve ürünler tek ekranda.
class ReceiptFormPage extends StatefulWidget {
  const ReceiptFormPage({super.key, this.initial, this.initialDraft});
  final Expense? initial; // doluysa düzenleme
  final ReceiptDraft? initialDraft; // OCR taramasından gelen taslak

  @override
  State<ReceiptFormPage> createState() => _ReceiptFormPageState();
}

class _ReceiptFormPageState extends State<ReceiptFormPage> {
  late final ReceiptDraft _draft;
  late final TextEditingController _merchant;
  late final TextEditingController _note;
  late final List<_Row> _rows;
  bool _busy = false;

  bool get _editing => widget.initial != null;

  double get _total => _rows.fold(0.0, (s, r) => s + r.value);

  /// Kaydedilecek tutar: kalemler − fişteki indirim.
  double get _net => netTotal(_total, _draft.discount);

  @override
  void initState() {
    super.initState();
    _draft = _editing
        ? ReceiptDraft.from(widget.initial!)
        : (widget.initialDraft ?? ReceiptDraft());
    _merchant = TextEditingController(text: _draft.merchant);
    _note = TextEditingController(text: _draft.note);
    _rows = _draft.items
        .map(
          (i) => _Row(
            i.name,
            i.amount,
            categoryId: i.categoryId,
            suggestedCategoryId: i.suggestedCategoryId,
            review: i.categoryReview,
          ),
        )
        .toList();
    if (_rows.isEmpty) _rows.add(_Row('', null));
    if (appState.categories.isEmpty) appState.refresh();
  }

  @override
  void dispose() {
    _merchant.dispose();
    _note.dispose();
    for (final r in _rows) {
      r.dispose();
    }
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

  Future<void> _pickCategory() async {
    final id = await showChoiceSheet<int>(
      context,
      title: 'Kategori',
      options: [for (final c in appState.categories) (c.id, c.name)],
      selected: _draft.categoryId,
    );
    if (id != null) _setCategory(id);
  }

  /// Fiş kategorisini kullanıcı seçti: "kontrol edin" uyarısı kalkar. Otomatik öneriden farklıysa
  /// kayıtta sunucu bunu işletme için kişisel kural olarak öğrenir.
  void _setCategory(int id) => setState(() {
        _draft.categoryId = id;
        _draft.categoryNeedsReview = false;
      });

  String? _categoryName(int? id) =>
      appState.categories.where((x) => x.id == id).map((x) => x.name).firstOrNull;

  Future<void> _pickItemCategory(int i) async {
    final id = await showChoiceSheet<int>(
      context,
      title: 'Ürün kategorisi',
      options: [for (final c in appState.categories) (c.id, c.name)],
      selected: _rows[i].categoryId,
    );
    if (id != null) {
      setState(() {
        _rows[i].categoryId = id;
        _rows[i].review = false;
      });
    }
  }

  /// Taslağın fotoğraflarını ve ayrıştırılan alanları kaybetmeden tara ekranına geçer.
  Future<void> _goScan() async {
    if (_draft.pendingImages.isNotEmpty) {
      final ok = await showConfirmDialog(
        context,
        title: 'Tara ekranına geç',
        message:
            'Taranan/girilen alanlar yeniden taranınca değişecek. Fotoğraflar korunur. Devam edilsin mi?',
        confirmLabel: 'Devam',
      );
      if (!ok || !mounted) return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ScanPage(initialPages: _draft.pendingImages),
      ),
    );
  }

  Future<void> _showAddPhotoSheet() async {
    final bytes = await pickReceiptPhotos(
      context,
      room: kMaxReceiptPhotos - _draft.pendingImages.length,
    );
    if (bytes.isEmpty || !mounted) return;
    setState(() => _draft.pendingImages.addAll(bytes));
  }

  Future<void> _save() async {
    if (_draft.categoryId == null) {
      showMessage(context, 'Lütfen bir kategori seçin.');
      return;
    }
    final items = [
      for (final r in _rows)
        if (r.name.text.trim().isNotEmpty || r.value > 0)
          ExpenseItem(
            r.name.text.trim(),
            r.value,
            categoryId: r.categoryId,
            suggestedCategoryId: r.suggestedCategoryId,
          ),
    ];
    if (items.isEmpty || items.fold<double>(0, (s, i) => s + i.amount) <= 0) {
      showMessage(context, 'En az bir ürün ve tutar girin.');
      return;
    }
    _draft
      ..merchant = _merchant.text.trim()
      ..note = _note.text.trim()
      ..items = items;
    setState(() => _busy = true);
    try {
      final imagesOk = await appState.saveDraft(_draft);
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      showMessage(
        context,
        !imagesOk
            ? 'Fiş kaydedildi ancak fotoğraflar yüklenemedi; fiş detayından tekrar ekleyin.'
            : (_draft.id == null ? 'Fiş kaydedildi.' : 'Fiş güncellendi.'),
      );
    } on ApiException catch (e) {
      // Ağ hatasında kuyruğa alınmaz; form ekranda kalır, kullanıcı tekrar dener.
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TopBar(
              leading: BarAction('Vazgeç', onTap: () => Navigator.maybePop(context)),
              title: _editing ? 'Fişi düzenle' : 'Yeni fiş',
            ),
            if (!_editing)
              ModeSwitch(
                scanActive: false,
                onChange: (scan) {
                  if (scan) _goScan();
                },
              ),
            Expanded(
              child: ListView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                children: [
                  GroupedCard(
                    children: [
                      if (!_editing) _photoRow(c),
                      RowField(
                        label: 'Marka',
                        controller: _merchant,
                        hint: 'Marka adı girin',
                        textInputAction: TextInputAction.next,
                      ),
                      ListenableBuilder(
                        listenable: appState,
                        builder: (_, _) {
                          final name = appState.categories
                              .where((x) => x.id == _draft.categoryId)
                              .map((x) => x.name)
                              .firstOrNull;
                          return ListRow(
                            title: 'Kategori',
                            onTap: _pickCategory,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (name != null &&
                                    _draft.categoryAutoAssigned &&
                                    !_draft.categoryNeedsReview) ...[
                                  const AutoBadge(),
                                  const SizedBox(width: 8),
                                ],
                                Text(
                                  name ?? 'Seçin',
                                  style: FissioText.body(c, color: name == null ? c.mute : c.ink),
                                ),
                              ],
                            ),
                            chevron: true,
                          );
                        },
                      ),
                      ListRow(
                        title: 'Tarih',
                        vertical: 11,
                        onTap: _pickDate,
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: c.surf2,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            fmtDate(_draft.date),
                            style: FissioText.body(c, size: 15),
                          ),
                        ),
                      ),
                      RowField(
                        controller: _note,
                        hint: 'Açıklama (isteğe bağlı)',
                        maxLines: 3,
                        maxLength: 500,
                      ),
                    ],
                  ),
                  CategoryReviewBanner(
                    visible: _draft.categoryNeedsReview,
                    candidates: [
                      for (final cand in _draft.categoryCandidates)
                        if (cand.id != _draft.categoryId) (cand.id, cand.name),
                    ],
                    onPick: _setCategory,
                  ),
                  const SizedBox(height: 22),
                  SectionLabel('Ürünler · ${_rows.length}'),
                  const SizedBox(height: 8),
                  TotalMismatchBanner(
                    itemsTotal: _net,
                    receiptTotal: _draft.receiptTotal,
                    discount: _draft.discount,
                  ),
                  GroupedCard(
                    children: [
                      for (var i = 0; i < _rows.length; i++) _itemRow(c, i),
                      InkWell(
                        onTap: () => setState(() => _rows.add(_Row('', null))),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          child: Row(
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: c.accent,
                                ),
                                child: Icon(LucideIcons.plus, size: 14, color: c.onAccent),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'Ürün ekle',
                                style: FissioText.body(
                                  c,
                                  weight: FontWeight.w600,
                                  color: c.accentInk,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              decoration: BoxDecoration(
                color: c.bar,
                border: Border(top: BorderSide(color: c.line)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!keyboard) ...[
                    if (_draft.discount > 0) ...[
                      Row(
                        children: [
                          Text('İndirim', style: FissioText.body(c, size: 14, color: c.mute)),
                          const Spacer(),
                          Text(
                            '−${fmtMoney(_draft.discount)}',
                            style: FissioText.body(c, size: 14, color: c.mute),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                    ],
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          'Toplam',
                          style: FissioText.title(c, size: 16).copyWith(letterSpacing: 0),
                        ),
                        const Spacer(),
                        Text(
                          fmtMoney(_net),
                          style: FissioText.money(c, size: 20, weight: FontWeight.w800),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  PrimaryButton(
                    label: _editing ? 'Fişi güncelle' : 'Fişi oluştur',
                    busy: _busy,
                    onPressed: _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "Fotoğraf ekle" satırı + bekleyen fotoğrafların küçük resim şeridi.
  Widget _photoRow(FissioColors c) {
    final n = _draft.pendingImages.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _showAddPhotoSheet,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                DashedBox(
                  radius: kRadiusSm,
                  color: c.mute,
                  strokeWidth: 1.5,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(LucideIcons.camera, size: 20, color: c.accentInk),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Fotoğraf ekle',
                    style: FissioText.body(c, weight: FontWeight.w600, color: c.accentInk),
                  ),
                ),
                Text(
                  n == 0 ? 'İsteğe bağlı' : '$n/$kMaxReceiptPhotos',
                  style: FissioText.body(c, size: 13, color: c.mute),
                ),
              ],
            ),
          ),
        ),
        if (n > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: n,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(kRadiusSm),
                      child: Image.memory(
                        _draft.pendingImages[i],
                        width: 72,
                        height: 96,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: () => setState(() => _draft.pendingImages.removeAt(i)),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0x99000000),
                          ),
                          child: const Icon(LucideIcons.x, size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _itemRow(FissioColors c, int i) {
    final r = _rows[i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _itemFields(c, i),
        ListenableBuilder(
          listenable: appState,
          builder: (_, _) => ItemCategoryChip(
            name: _categoryName(r.categoryId),
            review: r.review,
            onTap: () => _pickItemCategory(i),
          ),
        ),
      ],
    );
  }

  Widget _itemFields(FissioColors c, int i) {
    final r = _rows[i];
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: TextField(
            controller: r.name,
            textInputAction: TextInputAction.next,
            cursorColor: c.accentInk,
            style: FissioText.body(c),
            decoration: InputDecoration(
              hintText: 'Ürün adı',
              hintStyle: FissioText.body(c, color: c.mute),
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextField(
            controller: r.amount,
            onChanged: (_) => setState(() {}),
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            cursorColor: c.accentInk,
            style: FissioText.money(c),
            decoration: InputDecoration(
              hintText: '0,00',
              hintStyle: FissioText.body(c, color: c.mute),
              suffixText: ' ₺',
              suffixStyle: FissioText.body(c, color: c.mute),
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Ürünü sil',
          visualDensity: VisualDensity.compact,
          icon: Icon(LucideIcons.x, size: 18, color: c.mute),
          onPressed: () => setState(() {
            _rows.removeAt(i).dispose();
            if (_rows.isEmpty) _rows.add(_Row('', null));
          }),
        ),
      ],
    );
  }
}
