import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'theme.dart';
import 'widgets.dart';

/// Tek satır metin soran diyalog; vazgeçilirse null döner.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initial = '',
  String hint = '',
  TextInputType? keyboardType,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PromptDialog(
      title: title,
      confirmLabel: confirmLabel,
      initial: initial,
      hint: hint,
      keyboardType: keyboardType,
    ),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.confirmLabel,
    required this.initial,
    required this.hint,
    this.keyboardType,
  });
  final String title;
  final String confirmLabel;
  final String initial;
  final String hint;
  final TextInputType? keyboardType;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: widget.keyboardType,
        style: FissioText.body(c),
        cursorColor: c.accentInk,
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: FissioText.body(c, color: c.mute),
          filled: true,
          fillColor: c.surf2,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(kRadiusSm),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Vazgeç', style: TextStyle(color: c.mute)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Onay diyaloğu; onaylanırsa true döner.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Vazgeç',
  bool destructive = false,
}) async {
  final c = context.c;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel, style: TextStyle(color: c.mute)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
            confirmLabel,
            style: destructive ? TextStyle(color: c.danger) : null,
          ),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Seçenek listesi sheet'i; seçilen değeri döndürür (vazgeçilirse null).
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  required T? selected,
}) {
  final c = context.c;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .7),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          children: [
            Text(title, style: FissioText.title(c, size: 22)),
            const SizedBox(height: 12),
            GroupedCard(
              children: [
                for (final o in options)
                  ListRow(
                    title: o.$2,
                    vertical: 14,
                    trailing: o.$1 == selected
                        ? Icon(LucideIcons.check, size: 18, color: c.accentInk)
                        : null,
                    onTap: () => Navigator.pop(ctx, o.$1),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
