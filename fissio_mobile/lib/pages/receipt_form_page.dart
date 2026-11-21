import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../budgets.dart' show parseMoneyInput;
import '../dialogs.dart';
import '../models.dart';
import '../receipt_parser/normalize.dart' show foldTR;
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
  const ReceiptFormPage({super.key, this.initial, this.initialDraft, this.app});
  final Expense? initial; // doluysa düzenleme
  final ReceiptDraft? initialDraft; // OCR taramasından gelen taslak

  /// Verilmezse global [appState] (testlerde sahte uygulama durumu verilir).
  final AppState? app;

  @override
  State<ReceiptFormPage> createState() => _ReceiptFormPageState();
}

class _ReceiptFormPageState extends State<ReceiptFormPage> {
  AppState get _app => widget.app ?? appState;
  late final ReceiptDraft _draft;
  late final TextEditingController _merchant;
  late final TextEditingController _note;
  late final TextEditingController _estimate;
  late final List<_Row> _rows;
  bool _busy = false;

  /// Kullanıcı "Her ay tekrarlanır" ayarına kendisi dokundu: otomatik seri önerisi bir daha üzerine yazmaz.
  bool _recurringTouched = false;

  /// Otomatik olarak devam ettirilen tekrarlayan serinin adı (bilgi notu için).
  String? _inheritedFrom;

  /// Devralınan serinin işletme adı. Seri anahtarı işletme adına bağlıdır; bulanık eşleşmede ("BEDAŞ A.Ş." → "BEDAŞ")
  /// fiş kaydedilirken bu ad kullanılır ki fiş seriyi SÜRDÜRSÜN, ikinci bir seri açıp toplamı çiftlemesin.
  String? _inheritedMerchant;

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
    _estimate = TextEditingController(
      text: _draft.recurringEstimate > 0 ? _draft.recurringEstimate.toStringAsFixed(2).replaceAll('.', ',') : '',
    );
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
    if (_app.categories.isEmpty) _app.refresh();
    _inheritSeries();
  }

  @override
  void dispose() {
    _merchant.dispose();
    _note.dispose();
    _estimate.dispose();
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
      options: [for (final c in _app.categories) (c.id, c.name)],
      selected: _draft.categoryId,
    );
    if (id != null) _setCategory(id);
  }

  /// Fiş kategorisini kullanıcı seçti: "kontrol edin" uyarısı kalkar. Otomatik öneriden farklıysa
  /// kayıtta sunucu bunu işletme için kişisel kural olarak öğrenir.
  void _setCategory(int id) {
    setState(() {
      _draft.categoryId = id;
      _draft.categoryNeedsReview = false;
    });
    _inheritSeries();
  }

  /// Yeni fiş, aktif profildeki bir tekrarlayan serinin (aynı kurum + kategori) yeni ay faturasıysa "Her ay
  /// tekrarlanır"ı, günü, türü ve tahmini seriden devralır: fiş seriyi sürdürür ve o ayın beklenen kalemi
  /// otomatik "ödendi" olur. Kullanıcı ayara dokunduysa ya da fiş düzenleniyorsa karışılmaz.
  void _inheritSeries() {
    if (_editing || _recurringTouched || _draft.recurringDay > 0) return;
    final s = _app.seriesFor(_merchant.text, _draft.categoryId, amount: _net);
    if (s == null) return;
    setState(() {
      _draft
        ..recurringDay = s.day
        ..recurringKind = s.kind
        ..recurringEstimate = s.estimate
        ..recurringRemind = s.remind;
      _estimate.text = s.estimate > 0 ? s.estimate.toStringAsFixed(2).replaceAll('.', ',') : '';
      _inheritedFrom = s.title;
      _inheritedMerchant = s.merchant;
    });
  }

  String? _categoryName(int? id) =>
      _app.categories.where((x) => x.id == id).map((x) => x.name).firstOrNull;

  Future<void> _pickItemCategory(int i) async {
    final id = await showChoiceSheet<int>(
      context,
      title: 'Ürün kategorisi',
      options: [for (final c in _app.categories) (c.id, c.name)],
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

  /// "Her ay tekrarlanır": açılınca ödeme günü fiş tarihinin günü olur; hatırlatıcı varsayılan açık.
  void _toggleRecurring(bool on) {
    _recurringTouched = true;
    setState(() {
      _draft.recurringDay = on ? _draft.date.day : 0;
      if (!on) {
        _inheritedFrom = null;
        _inheritedMerchant = null;
      }
    });
    if (on && _draft.recurringRemind) _app.notifier.requestPermission();
  }

  Future<void> _pickRecurringDay() async {
    final day = await showChoiceSheet<int>(
      context,
      title: 'Aylık ödeme günü',
      options: [for (var d = 1; d <= 31; d++) (d, 'Ayın $d. günü')],
      selected: _draft.recurringDay,
    );
    if (day != null) {
      _recurringTouched = true;
      setState(() => _draft.recurringDay = day);
    }
  }

  Widget _recurringCard(FissioColors c) {
    final on = _draft.recurringDay > 0;
    return GroupedCard(
      children: [
        ListRow(
          title: 'Her ay tekrarlanır',
          subtitle: 'Elektrik, su, internet, kira, abonelik gibi sabit giderler',
          leading: Icon(LucideIcons.repeat, size: 20, color: c.accentInk),
          trailing: Switch(
            key: const Key('recurring-switch'),
            value: on,
            activeTrackColor: c.accent,
            activeThumbColor: c.onAccent,
            onChanged: _toggleRecurring,
          ),
        ),
        if (on)
          ListRow(
            key: const Key('recurring-day'),
            title: 'Ödeme günü',
            onTap: _pickRecurringDay,
            chevron: true,
            trailing: Text('Ayın ${_draft.recurringDay}. günü', style: FissioText.body(c, color: c.mute)),
          ),
        if (on)
          ListRow(
            title: 'Ödeme hatırlatıcısı',
            subtitle: '3 gün kala ve ödeme gününde bildirim',
            trailing: Switch(
              key: const Key('recurring-remind-switch'),
              value: _draft.recurringRemind,
              activeTrackColor: c.accent,
              activeThumbColor: c.onAccent,
              onChanged: (v) {
                _recurringTouched = true;
                setState(() => _draft.recurringRemind = v);
                if (v) _app.notifier.requestPermission();
              },
            ),
          ),
        if (on)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedControl<RecurringKind>(
                  key: const Key('recurring-kind'),
                  value: _draft.recurringKind,
                  fontSize: 13,
                  onChanged: (k) {
                    _recurringTouched = true;
                    setState(() => _draft.recurringKind = k);
                  },
                  items: const [
                    SegmentItem(RecurringKind.fixed, 'Sabit tutar'),
                    SegmentItem(RecurringKind.variable, 'Değişken (fatura)'),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _draft.recurringKind == RecurringKind.fixed
                      ? 'Her ay aynı tutar: kira, abonelik, internet.'
                      : 'Tutarı her ay değişir: elektrik, su, doğalgaz. Projeksiyon son 3 ayın ortalamasını '
                            '(min-maks aralığıyla) kullanır; yeni ayın faturası girilince gerçek tutarla güncellenir.',
                  style: FissioText.body(c, size: 13, color: c.mute).copyWith(height: 1.35),
                ),
              ],
            ),
          ),
        if (on && _draft.recurringKind == RecurringKind.variable)
          RowField(
            key: const Key('recurring-estimate'),
            label: 'Tahmini tutar',
            controller: _estimate,
            hint: 'İsteğe bağlı, örn. 850',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            labelWidth: 120,
          ),
        if (on && _inheritedFrom != null)
          Padding(
            key: const Key('recurring-inherited'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Text(
              '"$_inheritedFrom" tekrarlayan giderinin devamı olarak işaretlendi; bu ayın kalemi ödendi sayılacak.'
              '${_inheritedMerchant != null && foldTR(_inheritedMerchant!) != foldTR(_merchant.text.trim()) ? ' İşletme adı "$_inheritedMerchant" olarak kaydedilir.' : ''}',
              style: FissioText.body(c, size: 13, color: c.accentInk).copyWith(height: 1.35),
            ),
          ),
      ],
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
    var merchant = _merchant.text.trim();
    // Devralınan seriye hâlâ uyuyorsa (kullanıcı adı başka bir işletmeye çevirmediyse) serinin adıyla kaydet.
    if (!_editing && _inheritedMerchant != null && _draft.recurringDay > 0) {
      final s = _app.seriesFor(merchant, _draft.categoryId, amount: _net);
      if (s != null) merchant = s.merchant;
    }
    _draft
      ..merchant = merchant
      ..note = _note.text.trim()
      ..recurringEstimate = _draft.recurringKind == RecurringKind.variable ? (parseMoneyInput(_estimate.text) ?? 0) : 0
      ..items = items;
    setState(() => _busy = true);
    try {
      final wasNew = _draft.id == null;
      final res = await _app.saveDraft(_draft);
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      showMessage(
        context,
        !res.imagesOk
            ? 'Fiş kaydedildi ancak fotoğraflar yüklenemedi; fiş detayından tekrar ekleyin.'
            : res.merged
            ? 'Resmi fatura, mevcut sipariş kaydıyla birleştirildi (yeni fiş oluşturulmadı).'
            : res.queued
            ? 'Çevrimdışı kaydedildi. Bağlantı gelince otomatik yüklenecek.'
            : res.localOnly
            ? 'Fiş yalnızca bu cihaza kaydedildi (bulut senkronu kapalı).'
            : (wasNew ? 'Fiş kaydedildi.' : 'Fiş güncellendi.'),
      );
    } on ApiException catch (e) {
      // Ağ dışı hata (doğrulama, yetki): form ekranda kalır. Ağ hatasında fiş zaten cihaz kuyruğuna alınır.
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
                        onChanged: (_) => _inheritSeries(),
                      ),
                      ListenableBuilder(
                        listenable: _app,
                        builder: (_, _) {
                          final name = _app.categories
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
                  const SizedBox(height: 14),
                  _recurringCard(c),
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
          listenable: _app,
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
            onChanged: (_) {
              setState(() {});
              // Bulanık seri eşleşmesi tutara da bakar: tutar girilince/değişince öneri yeniden denenir.
              _inheritSeries();
            },
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
