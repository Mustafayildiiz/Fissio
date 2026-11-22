import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'theme.dart';

enum ToastKind { info, success, error }

/// Süresi (eylem butonu yoksa / varsa). Testler `pump(duration)` ile bu süreyi aşar.
const kToastDuration = Duration(seconds: 3);
const kToastActionDuration = Duration(seconds: 6);

_ToastHandle? _current;

class _ToastHandle {
  _ToastHandle(this.entry);
  final OverlayEntry entry;
  bool removed = false;

  void remove() {
    if (removed) return;
    removed = true;
    if (identical(_current, this)) _current = null;
    try {
      entry.remove();
      entry.dispose();
    } catch (_) {
      // Overlay zaten yok edilmiş (sayfa kapandı): yapacak bir şey yok.
    }
  }
}

/// Ekranın ÜSTÜNDE (SafeArea altında) beliren, dokunarak ya da yukarı kaydırarak kapatılan bildirim. Alt gezinme çubuğunu
/// hiç kapatmaz. Aynı anda tek bildirim vardır; yenisi eskisinin yerine geçer. [actionLabel]/[onAction] ile tek eylem
/// butonu (ör. "Test metnini kopyala") eklenebilir; eylemli bildirim daha uzun kalır.
void showToast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  // Kapanmış bir sayfanın context'i: `Overlay.maybeOf` deaktive elemanda assert eder. Bildirim sessizce atlanır, böylece
  // await sonrası `showMessage/showError` çağrıları ayrıca korunmasa da çökmez.
  if (!context.mounted) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _current?.remove();
  late final _ToastHandle handle;
  final entry = OverlayEntry(
    builder: (_) => _ToastView(
      message: message,
      kind: kind,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: actionLabel == null ? kToastDuration : kToastActionDuration,
      onDone: () => handle.remove(),
    ),
  );
  handle = _ToastHandle(entry);
  _current = handle;
  overlay.insert(entry);
}

class _ToastView extends StatefulWidget {
  const _ToastView({
    required this.message,
    required this.kind,
    required this.duration,
    required this.onDone,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final ToastKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
  final VoidCallback onDone;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  // Bir kez kurulur: her build'de yeni CurvedAnimation, _anim'e dinleyici ekleyip hiç bırakmıyordu.
  late final CurvedAnimation _curved = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide =
      Tween<Offset>(begin: const Offset(0, -.6), end: Offset.zero).animate(_curved);
  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _anim.forward();
    _timer = Timer(widget.duration, _close);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _curved.dispose();
    _anim.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    if (mounted) {
      try {
        // `orCancel`: bildirim kapanırken yenisiyle değiştirilirse controller dispose edilir; düz TickerFuture o zaman
        // hiç tamamlanmaz (bekleyen future asılı kalırdı), orCancel TickerCanceled ile biter.
        await _anim.reverse().orCancel;
      } on TickerCanceled {
        // değiştirildi/dispose edildi
      }
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (icon, tone) = switch (widget.kind) {
      ToastKind.success => (LucideIcons.circleCheck, c.accent),
      ToastKind.error => (LucideIcons.circleAlert, c.danger),
      ToastKind.info => (LucideIcons.info, c.accent),
    };
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: FadeTransition(
            opacity: _curved,
            child: SlideTransition(
              position: _slide,
              child: Dismissible(
                key: const ValueKey('app-toast'),
                direction: DismissDirection.up,
                onDismissed: (_) {
                  _closing = true;
                  _timer?.cancel();
                  widget.onDone();
                },
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(kRadius),
                    onTap: _close,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                      decoration: BoxDecoration(
                        color: c.ink,
                        borderRadius: BorderRadius.circular(kRadius),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .22), blurRadius: 18, offset: const Offset(0, 6))],
                      ),
                      child: Row(
                        children: [
                          Icon(icon, size: 20, color: tone),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              widget.message,
                              key: const ValueKey('app-toast-text'),
                              style: FissioText.body(c, size: 14, weight: FontWeight.w600, color: c.bg).copyWith(height: 1.35),
                            ),
                          ),
                          if (widget.actionLabel != null)
                            TextButton(
                              key: const ValueKey('app-toast-action'),
                              onPressed: () {
                                widget.onAction?.call();
                                _close();
                              },
                              child: Text(widget.actionLabel!, style: FissioText.body(c, size: 13, weight: FontWeight.w800, color: c.accent)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
