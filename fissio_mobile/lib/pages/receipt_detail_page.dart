import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../dialogs.dart';
import '../models.dart';
import '../ocr/ocr_engine.dart';
import '../theme.dart';
import '../theme_controller.dart';
import '../widgets.dart';
import 'receipt_form_page.dart';
import 'receipt_images.dart';

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

/// Kağıt fişin tırtıklı kenarını izleyen yumuşak gölge.
class _PaperShadowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = _ZigZagClipper().getClip(size).shift(const Offset(0, 6));
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0x24000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Cihazdaki fişin bulutla ilişkisini açıklar.
class _SyncStateNote extends StatelessWidget {
  const _SyncStateNote(this.state);
  final SyncState state;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final pending = state == SyncState.pending;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.surf, borderRadius: BorderRadius.circular(kRadius)),
      child: Row(
        children: [
          Icon(pending ? LucideIcons.cloudUpload : LucideIcons.smartphone, size: 20, color: c.accentInk),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              pending
                  ? 'Bu fiş henüz buluta yüklenmedi; bağlantı gelince otomatik yüklenecek.'
                  : 'Bu fiş yalnızca bu cihazda (bulut senkronu kapalı).',
              style: FissioText.body(c, size: 14, color: c.mute),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Her ay tekrarlanır" bilgisi (düzenlemek için "Düzenle" > Her ay tekrarlanır).
class _RecurringNote extends StatelessWidget {
  const _RecurringNote(this.e);
  final Expense e;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      key: const Key('recurring-note'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.surf, borderRadius: BorderRadius.circular(kRadius)),
      child: Row(
        children: [
          Icon(LucideIcons.repeat, size: 20, color: c.accentInk),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Her ay tekrarlanır · ayın ${e.recurringDay}. günü'
              '${e.recurringRemind ? ' · hatırlatıcı açık' : ''}',
              style: FissioText.body(c, size: 14, color: c.mute),
            ),
          ),
        ],
      ),
    );
  }
}

class ReceiptDetailPage extends StatelessWidget {
  const ReceiptDetailPage({super.key, required this.id, this.app});
  final int id;

  /// Verilmezse global [appState] (testlerde sahte sunuculu örnek verilir).
  final AppState? app;
  AppState get _app => app ?? appState;

  Future<void> _delete(BuildContext context, Expense e) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Fişi sil',
      message: 'Bu fiş kalıcı olarak silinecek.',
      confirmLabel: 'Sil',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _app.deleteExpense(e.id);
      if (context.mounted) Navigator.of(context).pop();
    } on ApiException catch (err) {
      if (context.mounted) showError(context, err.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: Listenable.merge([_app, themeController]),
      builder: (context, _) {
        final e = _app.expenses.where((x) => x.id == id).firstOrNull;
        if (e == null) {
          // Silindi veya bulunamadı.
          return Scaffold(
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const NavBackBar(label: 'Fişler'),
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Fiş bulunamadı.', style: FissioText.body(c)),
                  ),
                ],
              ),
            ),
          );
        }
        final paper = themeController.receiptStyle == ReceiptStyle.paper;
        return Scaffold(
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NavBackBar(
                  label: 'Fişler',
                  trailing: BarAction(
                    'Düzenle',
                    bold: true,
                    onTap: () {
                      // Senkron kapalıyken bulut fişleri salt-okunurdur (yerel fişler serbestçe düzenlenir).
                      if (!e.isLocal && !_app.syncEnabled) {
                        showMessage(context, readOnlyCloudMessage);
                        return;
                      }
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ReceiptFormPage(initial: e),
                        ),
                      );
                    },
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                    children: [
                      if (paper) _PaperReceipt(e) else _ListReceipt(e),
                      if (e.isRecurring) ...[
                        const SizedBox(height: 16),
                        _RecurringNote(e),
                      ],
                      if (e.isLocal) ...[
                        const SizedBox(height: 16),
                        _SyncStateNote(e.syncState),
                      ],
                      const SizedBox(height: 16),
                      ReceiptImageStrip(expense: e),
                      const SizedBox(height: 16),
                      _DeleteRow(onTap: () => _delete(context, e)),
                      // Dijital fiş: sipariş kodu ve resmi fatura durumu (resmi kayıt kilitlidir: ikinci bir belge üzerine yazamaz).
                      if (e.orderId != null || e.hasOfficialInvoice) ...[
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            [
                              if (e.orderId != null) 'Sipariş No: ${e.orderId}',
                              if (e.hasOfficialInvoice) 'Resmi fatura bağlı' else 'Sipariş özeti (resmi fatura bekleniyor)',
                            ].join(' · '),
                            key: const Key('digital-note'),
                            textAlign: TextAlign.center,
                            style: FissioText.body(context.c, size: 12, color: context.c.mute.withValues(alpha: .7)),
                          ),
                        ),
                      ],
                      // Fişi hangi motor okudu (manuel/eski kayıtlarda yok): sönük, küçük bilgi satırı.
                      // Tercihler > "Fiş detayında OCR motorunu göster" kapalıysa satır hiç çizilmez.
                      if ((themeController.showOcrEngine ? ocrEngineDisplayName(e.ocrEngine) : null) case final engine?) ...[
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            'İşleyen Motor: $engine',
                            key: const Key('ocr-engine-note'),
                            style: FissioText.body(context.c, size: 12, color: context.c.mute.withValues(alpha: .7)),
                          ),
                        ),
                      ],
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

class _DeleteRow extends StatelessWidget {
  const _DeleteRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.surf,
      borderRadius: BorderRadius.circular(kRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(LucideIcons.trash2, size: 18, color: c.danger),
              const SizedBox(width: 10),
              Text(
                'Fişi sil',
                style: FissioText.body(
                  c,
                  weight: FontWeight.w600,
                  color: c.danger,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Yatay kesikli çizgi (kağıt fişteki ayırıcı).
class _DashedLine extends StatelessWidget {
  const _DashedLine({this.margin = EdgeInsets.zero});
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final color = context.c.line;
    return Padding(
      padding: margin,
      child: LayoutBuilder(
        builder: (context, box) {
          final n = (box.maxWidth / 10).floor();
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < n; i++)
                Container(width: 6, height: 2, color: color),
            ],
          );
        },
      ),
    );
  }
}

String _itemName(ExpenseItem it) => it.name.isEmpty ? 'Ürün' : it.name;

/// Varsayılan görünüm: tırtıklı kenarlı kağıt fiş.
class _PaperReceipt extends StatelessWidget {
  const _PaperReceipt(this.e);
  final Expense e;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return CustomPaint(
      painter: _PaperShadowPainter(),
      child: ClipPath(
        clipper: _ZigZagClipper(),
        child: Container(
          color: c.paper,
          padding: const EdgeInsets.fromLTRB(22, 30, 22, 34),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.merchant.isEmpty ? 'Marka yok' : e.merchant,
                          style: FissioText.title(c, size: 26),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${e.categoryName} · ${fmtDate(e.date)}',
                          style: FissioText.body(c, size: 14, color: c.mute),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const _DashedLine(margin: EdgeInsets.fromLTRB(0, 18, 0, 6)),
              if (e.items.isEmpty) _line(c, 'Toplam kalem', e.amount),
              for (final it in e.items) _line(c, _itemName(it), it.amount),
              const _DashedLine(margin: EdgeInsets.fromLTRB(0, 8, 0, 14)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    'Toplam',
                    style: FissioText.title(
                      c,
                      size: 18,
                    ).copyWith(letterSpacing: 0),
                  ),
                  const Spacer(),
                  Text(
                    fmtMoney(e.amount),
                    style: FissioText.money(
                      c,
                      size: 28,
                      weight: FontWeight.w800,
                      letterSpacing: -.5,
                    ),
                  ),
                ],
              ),
              if (e.note.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'AÇIKLAMA',
                  style: FissioText.label(c).copyWith(fontSize: 12),
                ),
                const SizedBox(height: 6),
                Text(
                  e.note,
                  style: FissioText.body(
                    c,
                    size: 14,
                    color: c.mute,
                  ).copyWith(height: 1.45),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(FissioColors c, String name, double amount) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            name,
            overflow: TextOverflow.ellipsis,
            style: FissioText.body(c, size: 15),
          ),
        ),
        const SizedBox(width: 12),
        Text(fmtMoney(amount), style: FissioText.money(c, size: 15)),
      ],
    ),
  );
}

/// Tercihlerden "Liste" seçilirse: büyük tutar + ürünler kartı.
class _ListReceipt extends StatelessWidget {
  const _ListReceipt(this.e);
  final Expense e;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e.merchant.isEmpty ? 'Marka yok' : e.merchant,
                style: FissioText.title(c, size: 30),
              ),
              const SizedBox(height: 6),
              Text.rich(
                TextSpan(
                  style: FissioText.body(c, size: 14, color: c.mute),
                  children: [
                    TextSpan(text: '${fmtDate(e.date)} · '),
                    TextSpan(
                      text: e.categoryName,
                      style: TextStyle(
                        color: c.accentInk,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  fmtMoney(e.amount),
                  style: FissioText.money(
                    c,
                    size: 44,
                    weight: FontWeight.w800,
                    letterSpacing: -1.3,
                  ).copyWith(height: 1),
                ),
              ),
            ],
          ),
        ),
        const Rule2(margin: EdgeInsets.symmetric(vertical: 20)),
        SectionLabel('Ürünler · ${e.items.length}'),
        const SizedBox(height: 8),
        GroupedCard(
          children: [
            if (e.items.isEmpty) _row(c, 'Toplam kalem', e.amount),
            for (final it in e.items)
              _row(
                c,
                _itemName(it),
                it.amount,
                // Kalem kategorisi fiş kategorisinden farklıysa (karma fiş) küçük etiket olarak göster.
                category: it.categoryName != null &&
                        it.categoryId != null &&
                        it.categoryId != e.categoryId
                    ? it.categoryName
                    : null,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                children: [
                  Text(
                    'Toplam',
                    style: FissioText.title(
                      c,
                      size: 16,
                    ).copyWith(letterSpacing: 0),
                  ),
                  const Spacer(),
                  Text(
                    fmtMoney(e.amount),
                    style: FissioText.money(
                      c,
                      size: 16,
                      weight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (e.note.isNotEmpty) ...[
          const SizedBox(height: 16),
          const SectionLabel('Açıklama'),
          const SizedBox(height: 8),
          GroupedCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            children: [
              Text(
                e.note,
                style: FissioText.body(
                  c,
                  size: 15,
                  color: c.mute,
                ).copyWith(height: 1.45),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _row(
    FissioColors c,
    String name,
    double amount, {
    String? category,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 13),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: FissioText.body(c),
              ),
              if (category != null)
                Text(
                  category,
                  overflow: TextOverflow.ellipsis,
                  style: FissioText.body(c, size: 12, color: c.mute),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(fmtMoney(amount), style: FissioText.money(c)),
      ],
    ),
  );
}
