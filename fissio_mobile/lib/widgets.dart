import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'models.dart';
import 'theme.dart';
import 'toast.dart';

export 'toast.dart' show ToastKind, showToast;

// ─── Başlıklar ve çizgiler ─────────────────────────────────────────────────

/// iOS tarzı büyük sayfa başlığı (34/800) ve sağda isteğe bağlı eylem (avatar vb.).
class LargeTitleHeader extends StatelessWidget {
  const LargeTitleHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: Text(title, style: FissioText.title(c))),
          ?trailing,
        ],
      ),
    );
  }
}

/// Bölüm etiketi: 13/600, büyük harf, geniş harf aralığı.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.padding});
  final String text;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(4, 0, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(text.toUpperCase(), style: FissioText.label(c)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 2px kalın ayırıcı çizgi.
class Rule2 extends StatelessWidget {
  const Rule2({super.key, this.margin = const EdgeInsets.fromLTRB(20, 20, 20, 18)});
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) =>
      Container(height: 2, margin: margin, color: context.c.rule);
}

/// "Profil 1" → "P1", "Ev" → "E", "Mustafa Yıldız" → "MY".
String initialsOf(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  String first(String w) => w.characters.first.toUpperCase();
  if (words.length == 1) return first(words[0]);
  return first(words[0]) + first(words[1]);
}

/// Yuvarlak avatar (baş harf).
class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 36, this.filled = false, this.onTap});
  final String name;
  final double size;

  /// true: vurgu rengi zemin, false: surf2.
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final initial = initialsOf(name);
    final circle = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? c.accent : c.surf2,
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w800,
          fontSize: size * .42,
          color: filled ? c.onAccent : c.ink,
        ),
      ),
    );
    if (onTap == null) return circle;
    return Semantics(
      button: true,
      label: 'Profil ve ayarlar',
      child: GestureDetector(onTap: onTap, child: circle),
    );
  }
}

// ─── Üst çubuklar ──────────────────────────────────────────────────────────

/// iOS stili geri çubuğu: "‹ Fişler" solda, isteğe bağlı eylem sağda.
class NavBackBar extends StatelessWidget {
  const NavBackBar({super.key, this.label = 'Geri', this.trailing, this.onBack});
  final String label;
  final Widget? trailing;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
        child: Row(
          children: [
            InkWell(
              onTap: onBack ?? () => Navigator.maybePop(context),
              borderRadius: BorderRadius.circular(kRadiusSm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.chevronLeft, size: 26, color: c.accentInk),
                    Text(label, style: FissioText.body(c, size: 17, color: c.accentInk)),
                  ],
                ),
              ),
            ),
            const Spacer(),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Ortada başlık, solda/sağda metin eylemi olan çubuk ("Vazgeç | Yeni fiş | …").
class TopBar extends StatelessWidget {
  const TopBar({super.key, this.leading, this.title, this.trailing});
  final Widget? leading;
  final String? title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Align(alignment: Alignment.centerLeft, child: leading),
            ),
            if (title != null)
              Text(title!, style: FissioText.body(c, size: 17, weight: FontWeight.w600)),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: trailing),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vurgu renginde metin eylemi ("Vazgeç", "Bitti", "Düzenle").
class BarAction extends StatelessWidget {
  const BarAction(this.label, {super.key, required this.onTap, this.bold = false, this.color});
  final String label;
  final VoidCallback? onTap;
  final bool bold;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Text(
          label,
          style: FissioText.body(
            c,
            size: 17,
            weight: bold ? FontWeight.w600 : FontWeight.w400,
            color: color ?? c.accentInk,
          ),
        ),
      ),
    );
  }
}

// ─── Gruplu liste (iOS "inset grouped") ────────────────────────────────────

/// Yuvarlak kenarlı surf kartı; çocukları arasına hairline ayırıcı koyar.
class GroupedCard extends StatelessWidget {
  const GroupedCard({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.dividers = true,
  });
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final bool dividers;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0 && dividers) rows.add(Divider(height: 1, thickness: 1, color: c.line));
      rows.add(children[i]);
    }
    // Material (dekorlu Container değil): içindeki InkWell dokunma efekti kartın arkasında kalıp görünmez olmasın.
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: c.surf,
        borderRadius: BorderRadius.circular(kRadius),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: padding,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        ),
      ),
    );
  }
}

/// Gruplu kart içindeki satır: [ikon] başlık … sağ içerik [›].
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.leading,
    this.trailing,
    this.subtitle,
    this.onTap,
    this.chevron = false,
    this.titleColor,
    this.vertical = 13,
  });
  final String title;
  final Widget? leading;
  final Widget? trailing;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool chevron;
  final Color? titleColor;
  final double vertical;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: vertical),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: FissioText.body(c, color: titleColor)),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!, style: FissioText.body(c, size: 13, color: c.mute)),
                  ),
              ],
            ),
          ),
          ?trailing,
          if (chevron) ...[
            const SizedBox(width: 6),
            Icon(LucideIcons.chevronRight, size: 16, color: c.mute),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

/// Gruplu kart içinde "Etiket ........ değer" biçiminde metin alanı satırı.
/// [label] null ise alan tüm genişliği kaplar (ör. Açıklama).
class RowField extends StatelessWidget {
  const RowField({
    super.key,
    this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.obscure = false,
    this.onSubmitted,
    this.onChanged,
    this.autofocus = false,
    this.maxLines = 1,
    this.maxLength,
    this.textInputAction,
    this.autofillHints,
    this.labelWidth = 92,
    this.vertical = 15,
    this.textAlign,
    this.style,
  });
  final String? label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final bool obscure;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final int maxLines;
  final int? maxLength;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final double labelWidth;
  final double vertical;
  final TextAlign? textAlign;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final field = TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      autofocus: autofocus,
      maxLines: obscure ? 1 : maxLines,
      minLines: 1,
      maxLength: maxLength,
      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      textAlign: textAlign ?? (label == null ? TextAlign.start : TextAlign.end),
      cursorColor: c.accentInk,
      style: style ?? FissioText.body(c),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: FissioText.body(c, color: c.mute),
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: vertical),
      child: label == null
          ? field
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(width: labelWidth, child: Text(label!, style: FissioText.body(c))),
                Expanded(child: field),
              ],
            ),
    );
  }
}

/// Küçük ikon karesi (ayar satırı, fiş satırı).
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.size = 40, this.radius = kRadiusSm, this.onSurf = true});
  final IconData icon;
  final double size;
  final double radius;

  /// true: surf2 zemin (kart içinde); false: surf zemin (sayfa zemininde).
  final bool onSurf;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: onSurf ? c.surf2 : c.surf,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(icon, size: size * .5, color: c.ink),
    );
  }
}

// ─── Segmented control ve filtre hapları ───────────────────────────────────

class SegmentItem<T> {
  const SegmentItem(this.value, this.label, {this.icon});
  final T value;
  final String label;
  final IconData? icon;
}

class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.fontSize = 14,
  });
  final List<SegmentItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.surf2,
        borderRadius: BorderRadius.circular(kRadiusSm),
      ),
      child: Row(
        children: [
          for (final it in items)
            Expanded(
              child: Semantics(
                button: true,
                selected: it.value == value,
                label: it.label,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(it.value),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                      color: it.value == value ? c.surf : Colors.transparent,
                      borderRadius: BorderRadius.circular(kRadiusSm - 2),
                      boxShadow: it.value == value
                          ? const [
                              BoxShadow(
                                color: Color(0x1F000000),
                                blurRadius: 3,
                                offset: Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (it.icon != null) ...[
                          Icon(
                            it.icon,
                            size: 15,
                            color: it.value == value ? c.ink : c.mute,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            it.label,
                            overflow: TextOverflow.ellipsis,
                            style: FissioText.body(
                              c,
                              size: fontSize,
                              weight: FontWeight.w600,
                              color: it.value == value ? c.ink : c.mute,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Arama/filtre çipi: aktifken ink dolgu, değilken 1.5px çerçeve.
class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.active = false,
    this.dropdown = false,
  });
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool active;
  final bool dropdown;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = active ? c.bg : c.ink;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? c.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(kRadiusPill),
          border: active ? null : Border.all(color: c.line, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 6)],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FissioText.body(c, size: 14, weight: FontWeight.w600, color: fg),
              ),
            ),
            if (dropdown) ...[
              const SizedBox(width: 4),
              Icon(LucideIcons.chevronDown, size: 14, color: fg),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Düğmeler ──────────────────────────────────────────────────────────────

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.compact = false,
    this.expand = true,
    this.icon,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool compact;

  /// true: kullanılabilir tüm genişliği kaplar.
  final bool expand;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final button = FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        disabledBackgroundColor: c.accent.withValues(alpha: .5),
        disabledForegroundColor: c.onAccent.withValues(alpha: .8),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 18 : 24,
          vertical: compact ? 10 : 15,
        ),
        textStyle: const TextStyle(
          fontSize: 16,
          fontFamily: fontFamily,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: busy
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.onAccent),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
                Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              ],
            ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// Kesikli çerçeveli kutu (yeni profil, fotoğraf ekle).
class DashedBox extends StatelessWidget {
  const DashedBox({
    super.key,
    required this.child,
    this.radius = kRadius,
    this.color,
    this.strokeWidth = 2,
  });
  final Widget child;
  final double radius;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedPainter(
        color: color ?? context.c.line,
        radius: radius,
        strokeWidth: strokeWidth,
      ),
      child: child,
    );
  }
}

class _DashedPainter extends CustomPainter {
  _DashedPainter({required this.color, required this.radius, required this.strokeWidth});
  final Color color;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    const dash = 7.0, gap = 5.0;
    for (final PathMetric m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) =>
      old.color != color || old.radius != radius || old.strokeWidth != strokeWidth;
}

// ─── Fiş satırı ────────────────────────────────────────────────────────────

class ReceiptTile extends StatelessWidget {
  const ReceiptTile({
    super.key,
    required this.expense,
    required this.onTap,
    this.card = false,
    this.divider = true,
  });
  final Expense expense;
  final VoidCallback onTap;

  /// true: surf kartı içinde ayrı satır (Özet); false: liste satırı (Fişler).
  final bool card;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final name = expense.merchant.isEmpty ? 'Marka yok' : expense.merchant;
    final content = Row(
      children: [
        IconTile(LucideIcons.receipt, onSurf: card),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FissioText.body(c, weight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                '${fmtDate(expense.date)} · ${expense.categoryName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FissioText.body(c, size: 13, color: c.mute),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(fmtMoney(expense.amount), style: FissioText.money(c)),
        const SizedBox(width: 6),
        Icon(LucideIcons.chevronRight, size: 16, color: c.mute),
      ],
    );
    final padded = Padding(
      padding: EdgeInsets.symmetric(vertical: 12, horizontal: card ? 16 : 0),
      child: content,
    );
    final tile = card
        ? Material(
            color: c.surf,
            borderRadius: BorderRadius.circular(kRadius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(onTap: onTap, child: padded),
          )
        : InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                border: divider ? Border(bottom: BorderSide(color: c.line)) : null,
              ),
              child: padded,
            ),
          );
    return tile;
  }
}

// ─── Alt gezinme çubuğu ────────────────────────────────────────────────────

/// Özet · (+) · Fişler. Ortadaki "+" bir sekme değil eylemdir.
class FissioTabBar extends StatelessWidget {
  const FissioTabBar({
    super.key,
    required this.index,
    required this.onTab,
    required this.onAdd,
  });
  final int index;
  final ValueChanged<int> onTab;
  final VoidCallback onAdd;

  static const _raise = 20.0;
  static const _content = 56.0;

  /// Çubuğun (yükseltilmiş "+" dahil) toplam yüksekliği; listeler alt boşluk için kullanır.
  static double heightOf(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    return _raise + _content + (inset < 8 ? 8 : inset);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final inset = MediaQuery.paddingOf(context).bottom;
    final barH = _content + (inset < 8 ? 8 : inset);
    return SizedBox(
      height: _raise + barH,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: barH,
            // Not: eskiden σ=20 BackdropFilter vardı; `c.bar` zaten ~%94 opak olduğundan görsel fark ihmal edilebilir,
            // ama kayan listenin üstündeki canlı bulanıklık her karede GPU'da tüm çubuğu yeniden işliyordu.
            child: Container(
              padding: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                color: c.bar,
                border: Border(top: BorderSide(color: c.line)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _tab(c, 0, LucideIcons.house, 'Özet')),
                  const Expanded(child: SizedBox()),
                  Expanded(child: _tab(c, 1, LucideIcons.receipt, 'Fişler')),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Center(
              child: Semantics(
                button: true,
                label: 'Yeni fiş',
                child: GestureDetector(
                  onTap: onAdd,
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.accent,
                      boxShadow: [
                        BoxShadow(
                          color: c.accent.withValues(alpha: .4),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Icon(LucideIcons.plus, size: 28, color: c.onAccent),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tab(FissioColors c, int i, IconData icon, String label) {
    final on = index == i;
    final color = on ? c.accentInk : c.mute;
    return Semantics(
      button: true,
      selected: on,
      label: label,
      child: InkResponse(
        onTap: () => onTab(i),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: FissioText.body(c, size: 11, weight: FontWeight.w600, color: color)
                  .copyWith(height: 1),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Uyarılar ──────────────────────────────────────────────────────────────

class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surf,
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.wifiOff, color: c.danger, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: FissioText.body(c, size: 14))),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Tekrar dene')),
        ],
      ),
    );
  }
}

/// Uygulama içi bildirim: ekranın ÜSTÜNDE beliren toast (bkz. `toast.dart`); alt gezinmeyi kapatmaz.
void showMessage(BuildContext context, String msg, {ToastKind kind = ToastKind.info}) => showToast(context, msg, kind: kind);

/// Hata bildirimi (ör. `ApiException.message`): üst toast, hata renginde.
void showError(BuildContext context, String msg) => showToast(context, msg, kind: ToastKind.error);

/// Otomatik atanan fiş kategorisi güvenilir değilse ("Diğer"e düşüldü ya da düşük güven) uyarır ve
/// aday kategorileri tek dokunuşla seçtirir. [candidates] (id, ad) çiftleridir.
class CategoryReviewBanner extends StatelessWidget {
  const CategoryReviewBanner({
    super.key,
    required this.visible,
    required this.candidates,
    required this.onPick,
  });

  final bool visible;
  final List<(int, String)> candidates;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final c = context.c;
    final fg = c.isDark ? const Color(0xFFF5D77A) : const Color(0xFF7A5B00);
    final bg = c.isDark ? const Color(0x26E0A800) : const Color(0xFFFFF3CD);
    final border = c.isDark ? const Color(0x66E0A800) : const Color(0xFFE0A800);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(kRadiusSm),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.triangleAlert, color: fg, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Kategori otomatik olarak emin belirlenemedi. Lütfen kontrol edin; '
                  'seçiminiz sonraki taramalar için hatırlanır.',
                  style: TextStyle(color: fg, fontSize: 13),
                ),
              ),
            ],
          ),
          if (candidates.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final cand in candidates)
                  FilterPill(label: cand.$2, onTap: () => onPick(cand.$1)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Küçük "Otomatik" etiketi: kategori sunucu tarafından atandı ve kullanıcı değiştirmedi.
class AutoBadge extends StatelessWidget {
  const AutoBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.surf2,
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      child: Text(
        'Otomatik',
        style: FissioText.body(c, size: 11, weight: FontWeight.w600, color: c.accentInk),
      ),
    );
  }
}

/// Ürün satırındaki kategori çipi: kategori adı (atanmamışsa "Kategori seç"); düşük güvenli otomatik
/// atamada [review] true iken amber nokta gösterir.
class ItemCategoryChip extends StatelessWidget {
  const ItemCategoryChip({
    super.key,
    required this.name,
    required this.onTap,
    this.review = false,
  });

  final String? name;
  final VoidCallback onTap;
  final bool review;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final amber = c.isDark ? const Color(0xFFF5D77A) : const Color(0xFFB07C00);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (review) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(shape: BoxShape.circle, color: amber),
              ),
              const SizedBox(width: 6),
            ],
            Icon(LucideIcons.tag, size: 12, color: name == null ? c.mute : c.accentInk),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                name ?? 'Kategori seç',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FissioText.body(
                  c,
                  size: 12,
                  weight: FontWeight.w600,
                  color: name == null ? c.mute : c.accentInk,
                ),
              ),
            ),
            Icon(LucideIcons.chevronDown, size: 12, color: c.mute),
          ],
        ),
      ),
    );
  }
}

/// Kalem toplamı ile fiş toplamı farklıysa uyarı gösterir (fark < 0,01 ise hiçbir şey çizmez).
/// Kaydedilen tutar kalem toplamıdır (indirim varsa indirim düşülmüş hali; [itemsTotal] bu net
/// değerdir); bu yüzden kullanıcı tutarları kontrol etmelidir.
class TotalMismatchBanner extends StatelessWidget {
  const TotalMismatchBanner({
    super.key,
    required this.itemsTotal,
    required this.receiptTotal,
    this.discount = 0,
  });

  final double itemsTotal;
  final double? receiptTotal;
  final double discount;

  static bool mismatch(double itemsTotal, double? receiptTotal) =>
      receiptTotal != null && ((itemsTotal * 100).round() - (receiptTotal * 100).round()).abs() >= 1; // kuruş: float farkı (0.00999…) kaçmasın

  @override
  Widget build(BuildContext context) {
    if (!mismatch(itemsTotal, receiptTotal)) return const SizedBox.shrink();
    final c = context.c;
    final fg = c.isDark ? const Color(0xFFF5D77A) : const Color(0xFF7A5B00);
    final bg = c.isDark ? const Color(0x26E0A800) : const Color(0xFFFFF3CD);
    final border = c.isDark ? const Color(0x66E0A800) : const Color(0xFFE0A800);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(kRadiusSm),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.triangleAlert, color: fg, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              discount > 0
                  ? 'Kalemlerin indirimli toplamı (${fmtMoney(itemsTotal)}) fiş toplamından '
                        '(${fmtMoney(receiptTotal!)}) farklı. Kaydedilen tutar kalemlerin '
                        'toplamı eksi indirimdir (−${fmtMoney(discount)}); '
                        'lütfen tutarları kontrol edin.'
                  : 'Kalemlerin toplamı (${fmtMoney(itemsTotal)}) fiş toplamından '
                        '(${fmtMoney(receiptTotal!)}) farklı. Kaydedilen tutar kalemlerin '
                        'toplamıdır; lütfen tutarları kontrol edin.',
              style: TextStyle(color: fg, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
