import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';
import '../widgets.dart';

/// Hesap ekranlarının (giriş / kayıt / doğrulama / sıfırlama) ortak parçaları — "Fissio Hesap" tasarımı:
/// iOS gruplu liste gibi form kartı, etiket alanın içinde (küçük, üstte), yazı solda/ok sağda ana düğme.

/// Büyük başlık + alt metin + kalın çizgi.
class AccountHeader extends StatelessWidget {
  const AccountHeader({super.key, required this.title, this.subtitle, this.leading});
  final String title;
  final Widget? subtitle;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null) ...[leading!, const SizedBox(height: 14)],
              Text(title, style: FissioText.title(c)),
              if (subtitle != null) ...[const SizedBox(height: 10), subtitle!],
            ],
          ),
        ),
        const Rule2(margin: EdgeInsets.symmetric(vertical: 20)),
      ],
    );
  }
}

TextStyle accountSubtitleStyle(FissioColors c) =>
    FissioText.body(c, size: 16, color: c.mute).copyWith(height: 1.45);

/// Gruplu karttaki bir alan: üstte küçük etiket, altında değer; sağda isteğe bağlı simge/işaret.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.trailing,
    this.fieldKey,
  });
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? trailing;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: FissioText.body(c, size: 12, weight: FontWeight.w600, color: c.mute)),
                const SizedBox(height: 4),
                TextField(
                  key: fieldKey,
                  controller: controller,
                  obscureText: obscure,
                  autofocus: autofocus,
                  keyboardType: keyboardType,
                  textInputAction: textInputAction,
                  autofillHints: autofillHints,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  cursorColor: c.accentInk,
                  style: FissioText.body(c, size: 17),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: FissioText.body(c, size: 17, color: c.mute),
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

/// Şifre göster/gizle simgesi.
class EyeToggle extends StatelessWidget {
  const EyeToggle({super.key, required this.visible, required this.onTap});
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(visible ? LucideIcons.eyeOff : LucideIcons.eye, size: 20, color: context.c.mute),
      ),
    );
  }
}

/// Yazı solda, ok sağda ana düğme (diğer ekranlardaki gibi).
class ArrowButton extends StatelessWidget {
  const ArrowButton({super.key, required this.label, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = onPressed != null && !busy;
    return Opacity(
      opacity: onPressed == null && !busy ? .5 : 1,
      child: Material(
        color: c.accent,
        borderRadius: BorderRadius.circular(kRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadius),
          onTap: enabled ? onPressed : null,
          child: Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: fontFamily,
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                      color: c.onAccent,
                    ),
                  ),
                ),
                busy
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: c.onAccent),
                      )
                    : Icon(LucideIcons.arrowRight, size: 20, color: c.onAccent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Düz metin bağlantısı (accent renkli).
class LinkText extends StatelessWidget {
  const LinkText(this.text, {super.key, required this.onTap, this.size = 15});
  final String text;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          text,
          style: FissioText.body(
            c,
            size: size,
            weight: FontWeight.w600,
            color: onTap == null ? c.mute : c.accentInk,
          ),
        ),
      ),
    );
  }
}

/// Giriş/Kayıt arasında geçiş için altta sabit "Hesabın yok mu? Hesap oluştur".
class AccountSwitchLine extends StatelessWidget {
  const AccountSwitchLine({super.key, required this.prompt, required this.action, required this.onTap});
  final String prompt;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(prompt, style: FissioText.body(c, size: 15, color: c.mute)),
        LinkText(action, onTap: onTap),
      ],
    );
  }
}

// ─── Şifre kuralları ve gücü ─────────────────────────────────────────────

class PasswordRules {
  const PasswordRules(this.length, this.digit, this.upper, this.symbol, {this.bytesOk = true});
  final bool length;
  final bool digit;
  final bool upper;
  final bool symbol;

  factory PasswordRules.of(String p) => PasswordRules(
    p.length >= 8,
    RegExp(r'\d').hasMatch(p),
    p.runes.any((r) {
      final s = String.fromCharCode(r);
      return s != s.toLowerCase() && s == s.toUpperCase();
    }),
    RegExp(r'[^\p{L}\p{N}\s]', unicode: true).hasMatch(p),
    bytesOk: utf8.encode(p).length <= 72, // bcrypt sınırı
  );

  /// Sunucunun zorunlu kıldığı kurallar (sembol yalnızca önerilir).
  bool get valid => length && digit && upper && bytesOk;
  final bool bytesOk;
  int get score => [length, digit, upper, symbol].where((x) => x).length;
  String get label => switch (score) {
    0 || 1 => 'Zayıf',
    2 => 'Orta',
    3 => 'İyi',
    _ => 'Güçlü',
  };
}

/// 4 parçalı güç çubuğu + 4 kural (tasarım 1b).
class PasswordStrength extends StatelessWidget {
  const PasswordStrength({super.key, required this.rules});
  final PasswordRules rules;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget rule(String text, bool ok) => Row(
      children: [
        Icon(ok ? LucideIcons.check : LucideIcons.circle, size: 16, color: ok ? c.accentInk : c.mute),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: FissioText.body(c, size: 14, color: ok ? c.ink : c.mute))),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    for (var i = 0; i < 4; i++)
                      Expanded(
                        child: Container(
                          height: 4,
                          margin: EdgeInsets.only(right: i < 3 ? 4 : 0),
                          decoration: BoxDecoration(
                            color: i < rules.score ? c.accent : c.surf2,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(rules.label, style: FissioText.body(c, size: 13, weight: FontWeight.w600, color: c.accentInk)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            runSpacing: 8,
            children: [
              SizedBox(width: 160, child: rule('En az 8 karakter', rules.length)),
              SizedBox(width: 140, child: rule('Bir rakam', rules.digit)),
              SizedBox(width: 160, child: rule('Bir büyük harf', rules.upper)),
              SizedBox(width: 140, child: rule('Bir sembol', rules.symbol)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Onay kutusu satırı (şartlar).
class AccentCheck extends StatelessWidget {
  const AccentCheck({super.key, required this.value, required this.onChanged, required this.child});
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: value ? c.accent : Colors.transparent,
                border: value ? null : Border.all(color: c.line, width: 1.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: value ? Icon(LucideIcons.check, size: 14, color: c.onAccent) : null,
            ),
            const SizedBox(width: 12),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

// ─── 6 haneli kod alanı ──────────────────────────────────────────────────

/// 6 kutulu doğrulama kodu girişi: görünmez bir sayısal TextField'e bağlıdır (sayı klavyesi açılır,
/// yapıştırma ve SMS otomatik doldurma çalışır). Sonuncu hane girilince [onCompleted] çağrılır.
class OtpField extends StatefulWidget {
  const OtpField({
    super.key,
    required this.controller,
    this.onCompleted,
    this.onChanged,
    this.hasError = false,
    this.autofocus = true,
    this.enabled = true,
  });
  final TextEditingController controller;
  final ValueChanged<String>? onCompleted;
  final ValueChanged<String>? onChanged;
  final bool hasError;
  final bool autofocus;
  final bool enabled;

  @override
  State<OtpField> createState() => _OtpFieldState();
}

class _OtpFieldState extends State<OtpField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    widget.controller.addListener(_rebuild);
  }

  /// Üst widget denetleyiciyi değiştirirse dinleyici yenisine taşınır (eskisinde kalırsa alan güncellenmez ve
  /// eski denetleyici dispose edildiğinde sızar).
  @override
  void didUpdateWidget(OtpField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    _focus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final text = widget.controller.text;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _focus.requestFocus(),
      child: Stack(
        children: [
          // Görünmez ama odaklanabilir gerçek alan.
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                key: const Key('otp-input'),
                controller: widget.controller,
                focusNode: _focus,
                autofocus: widget.autofocus,
                enabled: widget.enabled,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                showCursor: false,
                enableInteractiveSelection: false,
                onChanged: (v) {
                  widget.onChanged?.call(v);
                  if (v.length == 6) widget.onCompleted?.call(v);
                },
              ),
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < 6; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 58,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.surf,
                      borderRadius: BorderRadius.circular(kRadiusSm),
                      border: widget.hasError
                          ? Border.all(color: c.danger, width: 2)
                          : (_focus.hasFocus && i == (text.length > 5 ? 5 : text.length))
                          ? Border.all(color: c.accent, width: 2)
                          : null,
                    ),
                    child: Text(
                      i < text.length ? text[i] : '',
                      style: TextStyle(
                        fontFamily: fontFamily,
                        fontWeight: FontWeight.w800,
                        fontSize: 26,
                        color: c.ink,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// "0:42" biçimi.
String mmss(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

/// Şifre soran diyalog (hesap silme onayı); vazgeçilirse null.
Future<String?> showPasswordPrompt(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PasswordPrompt(title: title, message: message, confirmLabel: confirmLabel, destructive: destructive),
  );
}

class _PasswordPrompt extends StatefulWidget {
  const _PasswordPrompt({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.destructive,
  });
  final String title;
  final String message;
  final String confirmLabel;
  final bool destructive;

  @override
  State<_PasswordPrompt> createState() => _PasswordPromptState();
}

class _PasswordPromptState extends State<_PasswordPrompt> {
  final _ctrl = TextEditingController();
  bool _visible = false;

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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message, style: FissioText.body(c, size: 14, color: c.mute)),
          const SizedBox(height: 12),
          TextField(
            key: const Key('password-prompt'),
            controller: _ctrl,
            autofocus: true,
            obscureText: !_visible,
            cursorColor: c.accentInk,
            style: FissioText.body(c),
            onSubmitted: (v) => Navigator.pop(context, v),
            decoration: InputDecoration(
              hintText: 'Şifren',
              hintStyle: FissioText.body(c, color: c.mute),
              filled: true,
              fillColor: c.surf2,
              isDense: true,
              suffixIcon: EyeToggle(visible: _visible, onTap: () => setState(() => _visible = !_visible)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(kRadiusSm),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Vazgeç', style: TextStyle(color: c.mute)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: Text(
            widget.confirmLabel,
            style: TextStyle(color: widget.destructive ? c.danger : c.accentInk, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
