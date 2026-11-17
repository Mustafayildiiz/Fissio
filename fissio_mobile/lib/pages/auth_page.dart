import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'profile_select_page.dart';

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
        MaterialPageRoute(builder: (_) => const ProfileSelectPage()),
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
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text('FISSIO', style: FissioText.label(c)),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      _register ? 'Hesap oluştur' : 'Giriş yap',
                      style: FissioText.title(c),
                    ),
                  ),
                  const Rule2(margin: EdgeInsets.symmetric(vertical: 20)),
                  SegmentedControl<bool>(
                    value: _register,
                    onChanged: (v) => setState(() {
                      _register = v;
                      _error = null;
                    }),
                    items: const [
                      SegmentItem(false, 'Giriş Yap', icon: LucideIcons.logIn),
                      SegmentItem(true, 'Kayıt Ol', icon: LucideIcons.userPlus),
                    ],
                  ),
                  const SizedBox(height: 16),
                  GroupedCard(
                    children: [
                      RowField(
                        label: 'E-posta',
                        controller: _email,
                        hint: 'E-posta giriniz',
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.next,
                      ),
                      RowField(
                        label: 'Şifre',
                        controller: _password,
                        hint: 'En az 6 karakter',
                        obscure: true,
                        onSubmitted: (_) => _submit(),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        _error!,
                        style: FissioText.body(c, size: 14, color: c.danger),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  PrimaryButton(
                    label: _register ? 'Kayıt Ol' : 'Giriş Yap',
                    busy: _busy,
                    onPressed: _submit,
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
