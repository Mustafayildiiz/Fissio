import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';
import 'theme_controller.dart';

/// Fissio logosu ("Fissio Logo Final" tasarımı): renkli yuvarlatılmış kare üzerinde, çapraz duran, beyaz ve
/// gölgeli yırtık fiş. Aynı çizim uygulama içindeki logo, splash/giriş/hakkında ve başlatıcı ikonlarının
/// (tool/generate_icons_test.dart ile üretilir) kaynağıdır; koordinatlar tasarımdaki 100×100 SVG'dir.

const _tilt = -14 * math.pi / 180;
const _receiptRed = Color(0xFFEC3013);
const _receiptGrey = Color(0xFFD6D3D3);

List<Offset> _pts(List<double> xy) => [for (var i = 0; i < xy.length; i += 2) Offset(xy[i], xy[i + 1])];

Path _poly(List<Offset> p, {Offset shift = Offset.zero}) {
  final path = Path()..moveTo(p.first.dx + shift.dx, p.first.dy + shift.dy);
  for (final o in p.skip(1)) {
    path.lineTo(o.dx + shift.dx, o.dy + shift.dy);
  }
  return path..close();
}

// Üst parça (yırtılan uç): M26 12H74V34L70 38 … 26 34Z, translate(5 -4).
final _topPiece = _poly(
  _pts([26, 12, 74, 12, 74, 34, 70, 38, 66, 34, 62, 38, 58, 34, 54, 38, 50, 34, 46, 38, 42, 34, 38, 38, 34, 34, 30, 38, 26, 34]),
  shift: const Offset(5, -4),
);

// Alt parça (üstü ve altı tırtıklı gövde).
final _bottomPiece = _poly(
  _pts([
    26, 46, 30, 42, 34, 46, 38, 42, 42, 46, 46, 42, 50, 46, 54, 42, 58, 46, 62, 42, 66, 46, 70, 42, 74, 46, //
    74, 86, 70, 90, 66, 86, 62, 90, 58, 86, 54, 90, 50, 86, 46, 90, 42, 86, 38, 90, 34, 86, 30, 90, 26, 86,
  ]),
);

/// 100×100'lük tasarım alanına fişi çizer ([canvas] ölçeklenmiş olmalı).
void _paintReceipt(Canvas canvas, {required bool shadow}) {
  canvas.save();
  canvas.translate(50, 50);
  canvas.rotate(_tilt);
  canvas.translate(-50, -50);
  if (shadow) {
    final sh = Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    canvas.drawPath(_topPiece.shift(const Offset(0, 3)), sh);
    canvas.drawPath(_bottomPiece.shift(const Offset(0, 3)), sh);
  }
  final white = Paint()..color = Colors.white;
  canvas.drawPath(_topPiece, white);
  canvas.drawPath(_bottomPiece, white);
  canvas.drawRect(const Rect.fromLTWH(32, 56, 22, 5), Paint()..color = _receiptRed);
  canvas.drawRect(const Rect.fromLTWH(32, 66, 34, 5), Paint()..color = _receiptGrey);
  canvas.drawRect(const Rect.fromLTWH(32, 76, 12, 5), Paint()..color = _receiptGrey);
  canvas.restore();
}

/// Tasarımda fiş, renkli karenin 96/144'ü kadardır (144 px kare içinde 96 px SVG).
const kLogoReceiptScale = 96 / 144;

/// Renkli yuvarlatılmış kare + fiş. [fill] false ise yalnızca fiş (adaptive ikon ön planı) çizilir.
class FissioLogoPainter extends CustomPainter {
  const FissioLogoPainter({
    required this.color,
    this.fill = true,
    this.rounded = true,
    this.shadow = true,
    this.receiptScale = kLogoReceiptScale,
  });
  final Color color;
  final bool fill;

  /// Fişin kareye oranı (ortalanır). Android adaptive ön planı güvenli bölge için daha küçük tutar.
  final double receiptScale;

  /// Tasarımdaki köşe yarıçapı: kenarın %22,2'si. false = tam kare (iOS ikonu; köşeyi sistem keser).
  final bool rounded;
  final bool shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    if (fill) {
      final r = rounded ? s * .222 : 0.0;
      canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & Size.square(s), Radius.circular(r)), Paint()..color = color);
    }
    canvas.save();
    canvas.translate(s * (1 - receiptScale) / 2, s * (1 - receiptScale) / 2);
    canvas.scale(s * receiptScale / 100);
    _paintReceipt(canvas, shadow: shadow);
    canvas.restore();
  }

  @override
  bool shouldRepaint(FissioLogoPainter old) =>
      old.color != color ||
      old.fill != fill ||
      old.rounded != rounded ||
      old.shadow != shadow ||
      old.receiptScale != receiptScale;
}

/// Uygulama içi logo. [color] verilmezse kullanıcının logo tercihi izlenir ([ThemeController.logoColor]:
/// "temaya uygun" ise vurgu rengi, değilse seçilen sabit renk).
class FissioLogo extends StatelessWidget {
  const FissioLogo({super.key, this.size = 72, this.color, this.controller});
  final double size;
  final Color? color;

  /// Testlerde farklı bir denetleyici verilebilir; varsayılan global [themeController].
  final ThemeController? controller;

  @override
  Widget build(BuildContext context) {
    if (color != null) return _build(color!);
    final ctrl = controller ?? themeController;
    return ListenableBuilder(listenable: ctrl, builder: (context, _) => _build(ctrl.logoColor));
  }

  Widget _build(Color c) => Semantics(
    label: 'Fissio logosu',
    image: true,
    child: SizedBox(
      key: const ValueKey('fissio-logo'),
      width: size,
      height: size,
      child: CustomPaint(painter: FissioLogoPainter(color: c)),
    ),
  );
}

/// Logo + "Fissio" yazısı (yatay sürüm).
class FissioWordmark extends StatelessWidget {
  const FissioWordmark({super.key, this.logoSize = 40, this.fontSize = 32});
  final double logoSize;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FissioLogo(size: logoSize),
        SizedBox(width: logoSize * .28),
        Text('Fissio', style: FissioText.title(c, size: fontSize).copyWith(height: 1)),
      ],
    );
  }
}
