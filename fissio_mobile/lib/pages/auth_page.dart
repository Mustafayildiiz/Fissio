import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'shell_page.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final mail = _email.text.trim();
    final pass = _password.text;
    if (mail.isEmpty || pass.isEmpty) {
      setState(() => _error = 'E-posta ve şifre gerekli.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_register) {
        await appState.register(mail, pass);
      } else {
        await appState.login(mail, pass);
      }
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ShellPage()),
        (_) => false,
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Fissio', style: TextStyle(color: Colors.white, fontSize: 34)),
                const SizedBox(height: 4),
                Text(
                  _register ? 'Hesap oluşturun' : 'Hesabınıza giriş yapın',
                  style: const TextStyle(color: AppColors.secondaryText, fontSize: 13),
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        style: const TextStyle(color: AppColors.darkText),
                        decoration: lightField('E-posta', hint: 'E-posta giriniz'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        onSubmitted: (_) => _submit(),
                        style: const TextStyle(color: AppColors.darkText),
                        decoration: lightField('Şifre', hint: 'En az 6 karakter'),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.danger, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 22),
                PrimaryButton(
                  label: _register ? 'Kayıt ol' : 'Giriş yap',
                  busy: _busy,
                  onPressed: _submit,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _register = !_register;
                            _error = null;
                          }),
                  child: Text(
                    _register
                        ? 'Zaten hesabım var, giriş yap'
                        : 'Hesabın yok mu? Kayıt ol',
                    style: const TextStyle(color: AppColors.secondaryText),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

