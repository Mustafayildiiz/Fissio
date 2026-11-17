import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'account_ready_page.dart';
import 'account_widgets.dart';

/// E-posta doğrulama (tasarım 1c): 6 haneli kod, geri sayımlı "Kodu tekrar gönder" (sunucu da 60 sn sınırı
/// uygular), hatalı / süresi dolmuş / çok fazla deneme uyarıları. Doğrulanınca oturum açılır.
class VerifyEmailPage extends StatefulWidget {
  const VerifyEmailPage({
    super.key,
    required this.email,
    this.initialCooldown = 60,
    this.onVerify,
    this.onResend,
    this.onSuccess,
  });
  final String email;
  final int initialCooldown;

  /// Testlerde sahte verilir; varsayılan: [AppState.verifyEmail] / [AppState.resendCode].
  final Future<void> Function(String email, String code)? onVerify;
  final Future<int> Function(String email)? onResend;

  /// Doğrulama başarılı olunca; varsayılan: "Hesap hazır" ekranı.
  final VoidCallback? onSuccess;

  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  final _code = TextEditingController();
  Timer? _timer;
  late int _remaining = widget.initialCooldown;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining > 0) setState(() => _remaining--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify(String code) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (widget.onVerify ?? appState.verifyEmail)(widget.email, code);
      if (!mounted) return;
      if (widget.onSuccess != null) {
        widget.onSuccess!();
      } else {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => AccountReadyPage(email: widget.email)),
          (_) => false,
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      // Hatalı/süresi dolmuş kodda alanı temizle; kullanıcı yeniden girsin ya da yeni kod istesin.
      _code.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    if (_remaining > 0 || _busy) return;
    setState(() => _error = null);
    try {
      final secs = await (widget.onResend ?? appState.resendCode)(widget.email);
      if (!mounted) return;
      setState(() => _remaining = secs);
      _code.clear();
      showMessage(context, 'Yeni kod gönderildi.');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.retryAfter != null) _remaining = e.retryAfter!;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hasError = _error != null;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
              children: [
                const NavBackBar(label: 'Geri'),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: c.accent.withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(kRadius),
                        ),
                        child: Icon(LucideIcons.mail, size: 26, color: c.accentInk),
                      ),
                      const SizedBox(height: 14),
                      Text('E-postanı doğrula', style: FissioText.title(c)),
                      const SizedBox(height: 14),
                      Text.rich(
                        TextSpan(
                          style: accountSubtitleStyle(c),
                          children: [
                            TextSpan(
                              text: widget.email,
                              style: TextStyle(color: c.ink, fontWeight: FontWeight.w600),
                            ),
                            const TextSpan(text: ' adresine 6 haneli bir kod gönderdik.'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                OtpField(
                  controller: _code,
                  hasError: hasError,
                  enabled: !_busy,
                  onChanged: (_) => setState(() => _error = null),
                  onCompleted: _verify,
                ),
                if (hasError)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                    child: Text(_error!, key: const Key('otp-error'), style: FissioText.body(c, size: 14, color: c.danger)),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(child: LinkText('Kodu tekrar gönder', onTap: _remaining > 0 ? null : _resend)),
                      if (_remaining > 0)
                        Text(
                          mmss(_remaining),
                          key: const Key('otp-countdown'),
                          style: FissioText.body(c, size: 15, weight: FontWeight.w600, color: c.mute)
                              .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: LinkText('E-postayı değiştir', onTap: () => Navigator.of(context).maybePop()),
                  ),
                ),
                const SizedBox(height: 16),
                ArrowButton(
                  label: 'Doğrula',
                  busy: _busy,
                  onPressed: _code.text.length == 6 ? () => _verify(_code.text) : () {
                    setState(() => _error = 'Lütfen 6 haneli kodu girin.');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
