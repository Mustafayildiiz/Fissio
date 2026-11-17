import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'account_widgets.dart';
import 'forgot_password_page.dart';
import 'profile_select_page.dart';
import 'verify_email_page.dart';

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Giriş / Hesap oluştur (tasarım 1a / 1b). Kayıttan sonra e-posta doğrulama kodu ekranına geçilir; hesap
/// doğrulanmadan aktifleşmez ve giriş yapılamaz.
class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.startInRegister = false});
  final bool startInRegister;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  late bool _register = widget.startInRegister;
  bool _showPass = false;
  bool _accepted = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _password2.dispose();
    super.dispose();
  }

  void _toggle() => setState(() {
    _register = !_register;
    _error = null;
  });

  Future<void> _submit() async {
    final mail = _email.text.trim();
    final pass = _password.text;
    if (!_emailRe.hasMatch(mail)) {
      setState(() => _error = 'Geçerli bir e-posta girin.');
      return;
    }
    if (_register) {
      if (!PasswordRules.of(pass).valid) {
        setState(() => _error = 'Şifre en az 8 karakter olmalı; bir rakam ve bir büyük harf içermeli.');
        return;
      }
      if (pass != _password2.text) {
        setState(() => _error = 'Şifreler eşleşmiyor.');
        return;
      }
      if (!_accepted) {
        setState(() => _error = 'Devam etmek için Kullanım Şartları ve Gizlilik Politikası\'nı kabul edin.');
        return;
      }
    } else if (pass.isEmpty) {
      setState(() => _error = 'Şifrenizi girin.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_register) {
        final cooldown = await appState.register(mail, pass, name: _name.text);
        if (!mounted) return;
        _openVerify(mail, cooldown);
      } else {
        await appState.login(mail, pass);
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ProfileSelectPage()),
          (_) => false,
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'email_not_verified') {
        _openVerify(mail, 60); // giriş yeni kod gönderdi
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openVerify(String mail, int cooldown) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VerifyEmailPage(email: mail, initialCooldown: cooldown)),
    );
  }

  Future<void> _forgot() async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ForgotPasswordPage(initialEmail: _email.text.trim())),
    );
    if (done == true && mounted) {
      showMessage(context, 'Şifren güncellendi. Yeni şifrenle giriş yap.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rules = PasswordRules.of(_password.text);
    final matches = _password2.text.isNotEmpty && _password2.text == _password.text;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, _register ? 8 : 28, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_register)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: GestureDetector(
                        onTap: _toggle,
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.chevron_left, color: c.accentInk, size: 28),
                              Text('Giriş', style: FissioText.body(c, size: 17, color: c.accentInk)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  AccountHeader(
                    title: _register ? 'Hesap oluştur' : 'Giriş yap',
                    subtitle: Text(
                      _register
                          ? 'Ücretsiz, bir dakikadan kısa sürer.'
                          : 'Fişlerine ve özetine kaldığın yerden devam et.',
                      style: accountSubtitleStyle(c),
                    ),
                  ),
                  GroupedCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      if (_register)
                        LabeledField(
                          label: 'Ad soyad',
                          controller: _name,
                          hint: 'Ad Soyad',
                          keyboardType: TextInputType.name,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.name],
                        ),
                      LabeledField(
                        label: 'E-posta',
                        controller: _email,
                        hint: 'ornek@eposta.com',
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        trailing: _register && _emailRe.hasMatch(_email.text.trim())
                            ? Icon(Icons.check, size: 20, color: c.accentInk)
                            : null,
                        onChanged: (_) => setState(() {}),
                      ),
                      LabeledField(
                        label: 'Şifre',
                        controller: _password,
                        hint: '••••••••',
                        obscure: !_showPass,
                        textInputAction: _register ? TextInputAction.next : TextInputAction.done,
                        autofillHints: _register ? const [AutofillHints.newPassword] : const [AutofillHints.password],
                        onChanged: (_) => setState(() {}),
                        onSubmitted: _register ? null : (_) => _submit(),
                        trailing: EyeToggle(visible: _showPass, onTap: () => setState(() => _showPass = !_showPass)),
                      ),
                      if (_register)
                        LabeledField(
                          label: 'Şifre tekrar',
                          controller: _password2,
                          hint: '••••••••',
                          obscure: !_showPass,
                          textInputAction: TextInputAction.done,
                          onChanged: (_) => setState(() {}),
                          trailing: _password2.text.isEmpty
                              ? null
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(matches ? Icons.check : Icons.close, size: 18,
                                        color: matches ? c.accentInk : c.danger),
                                    const SizedBox(width: 4),
                                    Text(
                                      matches ? 'Eşleşiyor' : 'Eşleşmiyor',
                                      style: FissioText.body(c, size: 13, weight: FontWeight.w600,
                                          color: matches ? c.accentInk : c.danger),
                                    ),
                                  ],
                                ),
                        ),
                    ],
                  ),
                  if (!_register) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: LinkText('Şifremi unuttum', onTap: _forgot),
                      ),
                    ),
                  ],
                  if (_register) ...[
                    const SizedBox(height: 12),
                    PasswordStrength(rules: rules),
                    const SizedBox(height: 8),
                    AccentCheck(
                      value: _accepted,
                      onChanged: (v) => setState(() => _accepted = v),
                      child: Text.rich(
                        TextSpan(
                          style: FissioText.body(c, size: 14, color: c.mute).copyWith(height: 1.45),
                          children: [
                            TextSpan(
                              text: 'Kullanım Şartları',
                              style: TextStyle(color: c.ink, fontWeight: FontWeight.w600),
                            ),
                            const TextSpan(text: '\'nı ve '),
                            TextSpan(
                              text: 'Gizlilik Politikası',
                              style: TextStyle(color: c.ink, fontWeight: FontWeight.w600),
                            ),
                            const TextSpan(text: '\'nı kabul ediyorum.'),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(_error!, style: FissioText.body(c, size: 14, color: c.danger)),
                    ),
                  ],
                  const SizedBox(height: 16),
                  ArrowButton(
                    label: _register ? 'Hesap oluştur' : 'Giriş yap',
                    busy: _busy,
                    onPressed: _submit,
                  ),
                  const SizedBox(height: 28),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: AccountSwitchLine(
                        prompt: _register ? 'Zaten hesabın var mı?' : 'Hesabın yok mu?',
                        action: _register ? 'Giriş yap' : 'Hesap oluştur',
                        onTap: _toggle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
