import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../onboarding_controller.dart';
import '../theme.dart';
import 'email_setup_wizard.dart';
import 'profile_select_page.dart';

/// Tanıtım akışının sayfa içerikleri (Fissio Onboarding tasarımı: tara → ekle → takip et).
const _kTitles = [
  'Fişini tara, gerisini Fissio halletsin',
  'Elle eklemek de birkaç saniye',
  'Paranın nereye gittiğini gör',
];
const _kBodies = [
  'Kamerayı fişe tutman yeterli. Marka, tarih ve ürünler otomatik okunur.',
  'Fiş bilgilerini ve ürünleri aynı ekranda gir, bir kategori seç ve kaydet.',
  'Haftalık harcama ve kategori dağılımı, tek ekranlık bir özette.',
];

/// Opsiyonel 4. adım (yalnızca ilk kayıtta, bulut senkronu açık ve sunucuda e-posta aktarımı yapılandırılmışsa).
const _kEmailTitle = 'E-Faturaların Otomatik Gelsin mi?';
const _kEmailBody =
    'Sana özel bir adres veriyoruz: e-fatura ve sipariş özeti maillerini bu adrese yönlendir, fişlerin kendiliğinden eklensin.';

/// 3 adımlı tanıtım (+ opsiyonel e-posta adımı). İlk kayıttan sonra (`signUp: true`) Profil seçiminden önce açılır;
/// Ayarlar'dan (`signUp: false`) açıldığında bitince yalnızca kapanır.
///
/// Renklerin hepsi `context.c` (FissioColors) tokenlarından gelir; açık/koyu mod ve
/// seçilen vurgu rengi otomatik uygulanır.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    this.controller,
    this.signUp = true,
    this.email,
    this.onDone,
    this.includeEmailStep = false,
    this.app,
  });

  /// Verilmezse global [onboardingController].
  final OnboardingController? controller;
  final bool signUp;

  /// Kayıt olan hesabın e-postası (`seen` bayrağının anahtarı).
  final String? email;

  /// Verilirse bitişte varsayılan gezinme yerine bu çağrılır (testler için).
  final VoidCallback? onDone;

  /// Sonuna "E-Faturaların Otomatik Gelsin mi?" adımı eklenir. Adımın varlığı sayfa AÇILMADAN belirlenir (bkz.
  /// `AccountReadyPage`): "1 / N" sayacı akış sırasında değişmez. Ayarlar'daki genel rehber bu adımı içermez.
  final bool includeEmailStep;

  /// Verilmezse global [appState] (e-posta adımındaki adres ve sihirbaz için).
  final AppState? app;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _pages = PageController();
  int _page = 0;
  bool _finishing = false;

  OnboardingController get _ctrl => widget.controller ?? onboardingController;
  AppState get _app => widget.app ?? appState;
  int get _count => _kTitles.length + (widget.includeEmailStep ? 1 : 0);
  bool get _last => _page == _count - 1;
  bool get _emailStep => widget.includeEmailStep && _page == _kTitles.length;

  @override
  void initState() {
    super.initState();
    // Kayıt akışı ekrana gelir gelmez işaretlenir: ortada kapansa da tekrar otomatik açılmaz.
    if (widget.signUp) _ctrl.markShownAtSignUp(widget.email);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int i) => _pages.animateToPage(
        i,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );

  /// "Şimdi Kur": interaktif sihirbazı açar; dönünce tanıtım tamamlanır.
  Future<void> _setupEmail() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EmailSetupWizardPage(app: widget.app)),
    );
    if (!mounted) return;
    await _finish(skipped: false);
  }

  Future<void> _finish({required bool skipped}) async {
    if (_finishing) return;
    _finishing = true;
    if (skipped) {
      await _ctrl.skip();
    } else {
      await _ctrl.complete();
    }
    if (!mounted) return;
    final done = widget.onDone;
    if (done != null) {
      done();
    } else if (widget.signUp) {
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ProfileSelectPage()),
        (_) => false,
      );
    } else {
      // pop(): PopScope'u (adım geri) atlar; rehber her adımdan doğrudan Ayarlar'a döner.
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return PopScope(
      // İlk sayfadan sonra geri tuşu bir önceki adıma döner.
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goTo(_page - 1);
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_page + 1} / $_count',
                        key: const ValueKey('onb-counter'),
                        style: FissioText.body(c, size: 15, weight: FontWeight.w600, color: c.mute),
                      ),
                      if (!_last)
                        InkWell(
                          key: const ValueKey('onb-skip'),
                          onTap: () => _finish(skipped: true),
                          borderRadius: BorderRadius.circular(kRadiusSm),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                            child: Text(
                              'Atla',
                              style: FissioText.body(
                                c,
                                size: 15,
                                weight: FontWeight.w600,
                                color: c.accentInk,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pages,
                  itemCount: _count,
                  onPageChanged: (i) {
                    setState(() => _page = i);
                    // E-posta adımı gösterildi: özellik tanıtıldı, ana sayfada ayrıca "Yeni" kartı çıkmaz.
                    if (widget.includeEmailStep && i == _kTitles.length) unawaited(_app.markEmailImportSeen());
                  },
                  itemBuilder: (_, i) => i >= _kTitles.length
                      ? _EmailStep(address: _app.inbound?.address)
                      : _OnboardingStep(index: i),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: _emailStep
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Dots(index: _page, count: _count),
                          const SizedBox(height: 18),
                          _OnbButton(
                            key: const ValueKey('onb-email-setup'),
                            label: 'Şimdi Kur',
                            expand: true,
                            onTap: _setupEmail,
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            width: double.infinity,
                            child: TextButton(
                              key: const ValueKey('onb-email-later'),
                              onPressed: () => _finish(skipped: false),
                              child: Text(
                                'Daha Sonra Ayarlardan Kur',
                                style: FissioText.body(c, size: 16, weight: FontWeight.w600, color: c.accentInk),
                              ),
                            ),
                          ),
                        ],
                      )
                    : _last
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Dots(index: _page, count: _count),
                          const SizedBox(height: 18),
                          _OnbButton(
                            key: const ValueKey('onb-primary'),
                            label: 'Başlayalım',
                            expand: true,
                            onTap: () => _finish(skipped: false),
                          ),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _Dots(index: _page, count: _count),
                          _OnbButton(
                            key: const ValueKey('onb-primary'),
                            label: 'Devam',
                            onTap: () => _goTo(_page + 1),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Bir adımın içeriği: hero + başlık + açıklama ───────────────────────────

class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({required this.index});
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 380,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(kRadius),
              child: switch (index) {
                0 => const _ScanHero(),
                1 => const _ManualHero(),
                _ => const _StatsHero(),
              },
            ),
          ),
          const SizedBox(height: 32),
          Text(
            _kTitles[index],
            key: ValueKey('onb-title-$index'),
            style: FissioText.title(c),
          ),
          const SizedBox(height: 14),
          Container(height: 2, color: c.rule),
          const SizedBox(height: 14),
          Text(
            _kBodies[index],
            key: ValueKey('onb-body-$index'),
            style: FissioText.body(c, size: 17, color: c.mute).copyWith(height: 1.45),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─── Opsiyonel 4. adım: e-posta ile otomatik aktarım ────────────────────────

class _EmailStep extends StatelessWidget {
  const _EmailStep({this.address});
  final String? address;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 380,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(kRadius),
              child: Container(
                key: const ValueKey('onb-hero-email'),
                color: c.surf2,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                      child: Icon(LucideIcons.mail, size: 40, color: c.onAccent),
                    ),
                    const SizedBox(height: 22),
                    Text('SANA ÖZEL ADRES', style: FissioText.label(c)),
                    const SizedBox(height: 10),
                    Container(
                      key: const ValueKey('onb-email-address'),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(color: c.surf, borderRadius: BorderRadius.circular(kRadiusSm)),
                      child: Text(
                        address ?? '…',
                        textAlign: TextAlign.center,
                        style: FissioText.body(c, size: 15, weight: FontWeight.w700).copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          Text(_kEmailTitle, key: const ValueKey('onb-title-email'), style: FissioText.title(c)),
          const SizedBox(height: 14),
          Container(height: 2, color: c.rule),
          const SizedBox(height: 14),
          Text(
            _kEmailBody,
            key: const ValueKey('onb-body-email'),
            style: FissioText.body(c, size: 17, color: c.mute).copyWith(height: 1.45),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─── Hero 1: tarama görünümü ────────────────────────────────────────────────

class _ScanHero extends StatelessWidget {
  const _ScanHero();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // Vizör bir "fotoğraf" olduğu için iki temada da koyu zemin + açık kâğıt kalır;
    // renkler sabit hex değil tema token setlerinden alınır.
    final cam = FissioColors.dark();
    final paper = FissioColors.light();

    Widget bar(double w, double h, Color color) => Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: w,
            child: Container(
              height: h,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
            ),
          ),
        );

    return Container(
      key: const ValueKey('onb-hero-scan'),
      color: cam.surf,
      child: Stack(
        children: [
          Positioned.fill(
            left: 84,
            right: 84,
            top: 40,
            bottom: 40,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
              decoration: BoxDecoration(
                color: paper.bg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: LayoutBuilder(
                builder: (context, box) {
                  final w = box.maxWidth;
                  Widget line(double a, double b) => Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          SizedBox(width: w * a, child: bar(1, 8, paper.surf2)),
                          SizedBox(width: w * b, child: bar(1, 8, paper.seg4)),
                        ],
                      );
                  Widget divider() => Container(
                        height: 2,
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        color: paper.surf2,
                      );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      bar(.6, 12, paper.seg4),
                      const SizedBox(height: 10),
                      bar(.4, 8, paper.surf2),
                      divider(),
                      line(.5, .18),
                      const SizedBox(height: 10),
                      line(.42, .18),
                      const SizedBox(height: 10),
                      line(.56, .18),
                      const SizedBox(height: 10),
                      line(.38, .18),
                      divider(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          SizedBox(width: w * .3, child: bar(1, 12, paper.mute)),
                          SizedBox(width: w * .28, child: bar(1, 12, paper.mute)),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          Positioned.fill(
            left: 64,
            right: 64,
            top: 24,
            bottom: 24,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    key: const ValueKey('onb-scan-corners'),
                    painter: _CornerPainter(c.accent),
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 10,
                  top: 0,
                  bottom: 0,
                  child: Align(
                    alignment: const Alignment(0, .04),
                    child: Container(
                      key: const ValueKey('onb-scan-line'),
                      height: 2,
                      decoration: BoxDecoration(
                        color: c.accent,
                        boxShadow: [BoxShadow(color: c.accent, blurRadius: 12)],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Vizör köşe ayraçları (4px çizgi, dış köşe yuvarlak).
class _CornerPainter extends CustomPainter {
  _CornerPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const len = 32.0, r = kRadiusSm;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.butt;
    final w = size.width, h = size.height;
    const inset = 2.0; // çizgi merkezi, 4px kalınlığın yarısı kadar içeride
    Path corner(double x, double y, double dx, double dy) => Path()
      ..moveTo(x + dx * len, y)
      ..lineTo(x + dx * r, y)
      ..arcToPoint(Offset(x, y + dy * r),
          radius: const Radius.circular(r), clockwise: dx * dy < 0)
      ..lineTo(x, y + dy * len);
    canvas.drawPath(corner(inset, inset, 1, 1), p);
    canvas.drawPath(corner(w - inset, inset, -1, 1), p);
    canvas.drawPath(corner(inset, h - inset, 1, -1), p);
    canvas.drawPath(corner(w - inset, h - inset, -1, -1), p);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.color != color;
}

// ─── Hero 2: manuel ekleme formu ────────────────────────────────────────────

class _ManualHero extends StatelessWidget {
  const _ManualHero();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final shadow = [
      BoxShadow(color: Colors.black.withValues(alpha: .08), blurRadius: 14, offset: const Offset(0, 4)),
    ];
    Widget card(List<Widget> children, {double vPad = 0}) => Container(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: vPad),
          decoration: BoxDecoration(
            color: c.surf,
            borderRadius: BorderRadius.circular(kRadius),
            boxShadow: shadow,
          ),
          child: Column(children: children),
        );
    Widget line(Widget left, Widget right, {double v = 15, bool border = true}) => Container(
          padding: EdgeInsets.symmetric(vertical: v),
          decoration: BoxDecoration(
            border: border ? Border(bottom: BorderSide(color: c.line)) : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [left, right],
          ),
        );
    final base = FissioText.body(c);
    final strong = FissioText.body(c, weight: FontWeight.w600);
    final money = FissioText.money(c);

    return Container(
      key: const ValueKey('onb-hero-manual'),
      color: c.surf2,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          card([
            line(Text('Marka', style: base), Text('Marka adı', style: strong)),
            line(
              Text('Kategori', style: base),
              Container(
                key: const ValueKey('onb-chip'),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: c.accent.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(kRadiusPill),
                ),
                child: Text(
                  'Kategori adı',
                  style: FissioText.body(c, size: 14, weight: FontWeight.w600, color: c.accentInk)
                      .copyWith(height: 1),
                ),
              ),
              v: 12,
              border: false,
            ),
          ]),
          const SizedBox(height: 10),
          card([
            line(Text('Ürün adı', style: base), Text('000,00 ₺', style: money)),
            line(Text('Ürün adı', style: base), Text('000,00 ₺', style: money)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                    child: Icon(LucideIcons.plus, size: 14, color: c.onAccent),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Ürün ekle',
                    style: FissioText.body(c, weight: FontWeight.w600, color: c.accentInk),
                  ),
                ],
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

// ─── Hero 3: özet kartı ─────────────────────────────────────────────────────

class _StatsHero extends StatelessWidget {
  const _StatsHero();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget col(double f, Color color) => Expanded(
          child: FractionallySizedBox(
            heightFactor: f,
            alignment: Alignment.bottomCenter,
            child: Container(
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
              ),
            ),
          ),
        );
    Widget seg(int flex, Color color) =>
        Expanded(flex: flex, child: ColoredBox(color: color));

    return Container(
      key: const ValueKey('onb-hero-stats'),
      color: c.surf2,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: c.surf,
          borderRadius: BorderRadius.circular(kRadius),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: .08), blurRadius: 14, offset: const Offset(0, 4)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SON 1 AY', style: FissioText.label(c)),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '000.000,00 ₺',
                style: FissioText.money(c, size: 34, weight: FontWeight.w800, letterSpacing: -34 * .03),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              height: 100,
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.rule, width: 2))),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  col(.46, c.surf2),
                  const SizedBox(width: 10),
                  col(.72, c.surf2),
                  const SizedBox(width: 10),
                  col(.58, c.surf2),
                  const SizedBox(width: 10),
                  col(.92, c.accent),
                ],
              ),
            ),
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(kRadiusSm),
              child: SizedBox(
                height: 10,
                child: Row(
                  children: [
                    seg(38, c.accent),
                    const SizedBox(width: 3),
                    seg(24, c.ink),
                    const SizedBox(width: 3),
                    seg(18, c.mute),
                    const SizedBox(width: 3),
                    seg(20, c.seg4),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Alt çubuk parçaları ────────────────────────────────────────────────────

/// Sayfa göstergesi: aktif nokta 22px'e uzar (animasyonlu), pasifler 6px.
class _Dots extends StatelessWidget {
  const _Dots({required this.index, required this.count});
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          AnimatedContainer(
            key: i == index ? const ValueKey('onb-dot-active') : ValueKey('onb-dot-$i'),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: i == index ? 22 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? c.accent : c.seg4,
              borderRadius: BorderRadius.circular(kRadiusPill),
            ),
          ),
        ],
      ],
    );
  }
}

/// Tasarımdaki "Devam →" / "Başlayalım →" düğmesi (54px, metin solda, ok sağda).
class _OnbButton extends StatelessWidget {
  const _OnbButton({super.key, required this.label, required this.onTap, this.expand = false});
  final String label;
  final VoidCallback onTap;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.accent,
      borderRadius: BorderRadius.circular(kRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: expand ? double.infinity : 150, minHeight: 54),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  label,
                  style: FissioText.title(c, size: 17).copyWith(color: c.onAccent, letterSpacing: 0),
                ),
                const SizedBox(width: 16),
                Icon(LucideIcons.arrowRight, size: 20, color: c.onAccent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
