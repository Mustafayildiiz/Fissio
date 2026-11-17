import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'account_widgets.dart';

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Şifre sıfırlama (tasarım 1d, kodla): 1) e-posta → 6 haneli kod gönderilir, 2) kod + yeni şifre.
/// Başarılıysa `true` ile kapanır (giriş ekranı bilgi mesajı gösterir). Şifre değişince tüm cihaz
/// oturumları sunucuda kapanır.
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({
    super.key,
    this.initialEmail = '',
    this.onSend,
    this.onReset,
  });
  final String initialEmail;

  /// Testlerde sahte verilir; varsayılan: [AppState.forgotPassword] / [AppState.resetPassword].
  final Future<int> Function(String email)? onSend;
  final Future<void> Function(String email, String code, String newPassword)? onReset;

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  Timer? _timer;
  int _remaining = 0;
  bool _codeStep = false;
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _code.dispose();
    _pass.dispose();
    _pass2.dispose();
    super.dispose();
  }

  void _countdown(int secs) {
    _timer?.cancel();
    setState(() => _remaining = secs);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining > 0) setState(() => _remaining--);
    });
  }

  Future<void> _send({bool resend = false}) async {
    final mail = _email.text.trim();
    if (!_emailRe.hasMatch(mail)) {
      setState(() => _error = 'Geçerli bir e-posta girin.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final secs = await (widget.onSend ?? appState.forgotPassword)(mail);
      if (!mounted) return;
      _countdown(secs);
      setState(() => _codeStep = true);
      if (resend) showMessage(context, 'Yeni kod gönderildi.');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.retryAfter != null) _remaining = e.retryAfter!;
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final rules = PasswordRules.of(_pass.text);
    if (_code.text.length != 6) {
      setState(() => _error = 'Lütfen 6 haneli kodu girin.');
      return;
    }
    if (!rules.valid) {
      setState(() => _error = 'Şifre en az 8 karakter olmalı; bir rakam ve bir büyük harf içermeli.');
      return;
    }
    if (_pass.text != _pass2.text) {
      setState(() => _error = 'Şifreler eşleşmiyor.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (widget.onReset ?? appState.resetPassword)(_email.text.trim(), _code.text, _pass.text);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      if (e.code == 'invalid_code' || e.code == 'code_expired' || e.code == 'too_many_attempts') _code.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final err = _error == null
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(_error!, key: const Key('reset-error'), style: FissioText.body(c, size: 14, color: c.danger)),
          );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
              children: [
                NavBackBar(
                  label: _codeStep ? 'E-posta' : 'Giriş',
                  onBack: _codeStep ? () => setState(() {
                    _codeStep = false;
                    _error = null;
                  }) : null,
                ),
                const SizedBox(height: 12),
                if (!_codeStep) ..._emailStep(c, err) else ..._codeStepWidgets(c, err),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _emailStep(FissioColors c, Widget? err) => [
    AccountHeader(
      title: 'Şifreni sıfırla',
      subtitle: Text(
        'Hesabına bağlı e-posta adresini gir, 6 haneli doğrulama kodunu gönderelim.',
        style: accountSubtitleStyle(c),
      ),
    ),
    GroupedCard(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        LabeledField(
          label: 'E-posta',
          controller: _email,
          hint: 'ornek@eposta.com',
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.email],
          onSubmitted: (_) => _send(),
        ),
      ],
    ),
    ?err,
    const SizedBox(height: 16),
    ArrowButton(label: 'Kod gönder', busy: _busy, onPressed: _send),
    const SizedBox(height: 28),
    Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.surf, borderRadius: BorderRadius.circular(kRadius)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info, size: 20, color: c.accentInk),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'E-posta birkaç dakika içinde gelmezse gereksiz klasörünü kontrol et.',
              style: FissioText.body(c, size: 14, color: c.mute).copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    ),
  ];

  List<Widget> _codeStepWidgets(FissioColors c, Widget? err) {
    final rules = PasswordRules.of(_pass.text);
    final matches = _pass2.text.isNotEmpty && _pass2.text == _pass.text;
    return [
      AccountHeader(
        title: 'Yeni şifre belirle',
        subtitle: Text.rich(
          TextSpan(
            style: accountSubtitleStyle(c),
            children: [
              TextSpan(text: _email.text.trim(), style: TextStyle(color: c.ink, fontWeight: FontWeight.w600)),
              const TextSpan(text: ' adresine gönderilen kodu ve yeni şifreni gir.'),
            ],
          ),
        ),
      ),
      OtpField(controller: _code, hasError: _error != null && _code.text.isEmpty, onChanged: (_) => setState(() {})),
      const SizedBox(height: 16),
      GroupedCard(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          LabeledField(
            label: 'Yeni şifre',
            controller: _pass,
            hint: '••••••••',
            obscure: !_show,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.newPassword],
            onChanged: (_) => setState(() {}),
            trailing: EyeToggle(visible: _show, onTap: () => setState(() => _show = !_show)),
          ),
          LabeledField(
            label: 'Şifre tekrar',
            controller: _pass2,
            hint: '••••••••',
            obscure: !_show,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            trailing: _pass2.text.isEmpty
                ? null
                : Text(
                    matches ? 'Eşleşiyor' : 'Eşleşmiyor',
                    style: FissioText.body(c, size: 13, weight: FontWeight.w600, color: matches ? c.accentInk : c.danger),
                  ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      PasswordStrength(rules: rules),
      ?err,
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(child: LinkText('Kodu tekrar gönder', onTap: _remaining > 0 || _busy ? null : () => _send(resend: true))),
            if (_remaining > 0)
              Text(mmss(_remaining), style: FissioText.body(c, size: 15, weight: FontWeight.w600, color: c.mute)),
          ],
        ),
      ),
      const SizedBox(height: 12),
      ArrowButton(label: 'Şifreyi güncelle', busy: _busy, onPressed: _reset),
    ];
  }
}
