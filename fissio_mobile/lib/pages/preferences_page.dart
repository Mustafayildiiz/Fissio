import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart' show ApiException;
import '../app_state.dart';
import '../logo.dart';
import '../ocr/ocr_engine.dart';
import '../theme.dart';
import '../theme_controller.dart';
import '../widgets.dart';
import 'home_layout_page.dart';

/// Tercihler: üç grupta — Görünüm ve Tema, Tarama ve OCR Motoru, Bildirimler ve Genel. Değişiklikler anında uygulanır.
class PreferencesPage extends StatelessWidget {
  const PreferencesPage({super.key, this.app});

  /// Verilmezse global [appState].
  final AppState? app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final a = app ?? appState;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: themeController,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const NavBackBar(label: 'Ayarlar'),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text('Tercihler', style: FissioText.title(c)),
              ),
              const Rule2(margin: EdgeInsets.fromLTRB(20, 16, 20, 20)),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  children: [
                    const _GroupHeader('Görünüm ve Tema', first: true),
                    _SwitchCard(
                      switchKey: const Key('theme-per-profile-switch'),
                      title: 'Profile özel tema kullan',
                      subtitle: themeController.perProfileTheme
                          ? 'Tema, vurgu rengi, logo ve widget teması '
                                '${a.activeProfile == null ? 'her profil' : '"${a.activeProfile!.name}" profili'} için ayrı saklanır; '
                                'profil değiştirince o profilin teması uygulanır.'
                          : 'Kapalıyken tüm profiller aynı (ortak) temayı kullanır.',
                      value: themeController.perProfileTheme,
                      onChanged: themeController.setPerProfileTheme,
                    ),
                    const SizedBox(height: 24),
                    const SectionLabel('Tema'),
                    const SizedBox(height: 8),
                    SegmentedControl<ThemeMode>(
                      value: themeController.themeMode,
                      onChanged: themeController.setThemeMode,
                      items: const [
                        SegmentItem(ThemeMode.system, 'Sistem'),
                        SegmentItem(ThemeMode.light, 'Açık'),
                        SegmentItem(ThemeMode.dark, 'Koyu'),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const SectionLabel('Vurgu rengi'),
                    const SizedBox(height: 8),
                    GroupedCard(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      children: [
                        Wrap(
                          alignment: WrapAlignment.spaceEvenly,
                          runSpacing: 14,
                          children: [
                            for (final o in kAccentOptions)
                              _Swatch(
                                name: o.name,
                                color: o.color,
                                selected: themeController.accent.toARGB32() ==
                                    o.color.toARGB32(),
                                onTap: () => themeController.setAccent(o.color),
                              ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const SectionLabel('Uygulama logosu'),
                    const SizedBox(height: 8),
                    const _LogoSection(),
                    const SizedBox(height: 24),
                    const SectionLabel('Widget renk teması'),
                    const SizedBox(height: 8),
                    SegmentedControl<WidgetTheme>(
                      key: const ValueKey('widget-theme'),
                      value: themeController.widgetTheme,
                      onChanged: themeController.setWidgetTheme,
                      items: const [
                        SegmentItem(WidgetTheme.system, 'Sistem'),
                        SegmentItem(WidgetTheme.light, 'Açık'),
                        SegmentItem(WidgetTheme.dark, 'Koyu'),
                        SegmentItem(WidgetTheme.brand, 'Marka'),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                      child: Text(
                        switch (themeController.widgetTheme) {
                          WidgetTheme.system => 'Ana ekran widget\'ları telefonun açık/koyu temasını izler.',
                          WidgetTheme.light => 'Ana ekran widget\'ları her zaman açık renkte olur.',
                          WidgetTheme.dark => 'Ana ekran widget\'ları her zaman koyu renkte olur.',
                          WidgetTheme.brand => 'Ana ekran widget\'ları logo rengini arka plan olarak kullanır.',
                        },
                        style: FissioText.body(c, size: 13, color: c.mute),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const SectionLabel('Fiş detayı'),
                    const SizedBox(height: 8),
                    SegmentedControl<ReceiptStyle>(
                      value: themeController.receiptStyle,
                      onChanged: themeController.setReceiptStyle,
                      items: const [
                        SegmentItem(ReceiptStyle.paper, 'Fiş', icon: LucideIcons.receipt),
                        SegmentItem(ReceiptStyle.list, 'Liste', icon: LucideIcons.list),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                      child: Text(
                        themeController.receiptStyle == ReceiptStyle.paper
                            ? 'Fişi kağıt fiş görünümünde gösterir.'
                            : 'Fiş bilgilerini ve ürünleri liste halinde gösterir.',
                        style: FissioText.body(c, size: 13, color: c.mute),
                      ),
                    ),
                    const _GroupHeader('Tarama ve OCR Motoru'),
                    const SectionLabel('Fiş okuma'),
                    const SizedBox(height: 8),
                    SegmentedControl<OcrMode>(
                      key: const ValueKey('ocr-mode'),
                      value: themeController.ocrMode,
                      onChanged: themeController.setOcrMode,
                      items: const [
                        SegmentItem(OcrMode.auto, 'Otomatik', icon: LucideIcons.sparkles),
                        SegmentItem(OcrMode.server, 'Sunucu', icon: LucideIcons.cloud),
                        SegmentItem(OcrMode.onDevice, 'Cihaz', icon: LucideIcons.smartphone),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                      child: Text(
                        switch (themeController.ocrMode) {
                          OcrMode.auto =>
                            'Bağlantı varken ve bulut senkronu açıkken yüksek doğruluklu sunucu OCR kullanılır, aksi halde cihaz içi OCR kullanılır.',
                          OcrMode.server =>
                            'Fotoğraf okunmak üzere sunucuya gönderilir (saklanmaz). Bağlantı yoksa ya da bulut senkronu kapalıyken cihaz içi OCR kullanılır.',
                          OcrMode.onDevice =>
                            'Cihaz İçi Hızlı OCR: fotoğraf cihazdan çıkmaz, internet gerekmez; doğruluk sunucuya göre daha düşük olabilir.',
                        },
                        style: FissioText.body(c, size: 13, color: c.mute),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const SectionLabel('Sunucu OCR motoru'),
                    const SizedBox(height: 8),
                    SegmentedControl<String>(
                      key: const ValueKey('ocr-engine'),
                      value: themeController.ocrEngine,
                      onChanged: themeController.setOcrEngine,
                      items: [
                        for (final e in appState.ocrFactory.availableEngines)
                          SegmentItem(e, ocrEngineLabel(e), icon: LucideIcons.server),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                      child: Text(
                        'Sunucu OCR kullanıldığında fişi okuyacak motor. Tarama ekranında otomatik uygulanır.',
                        style: FissioText.body(c, size: 13, color: c.mute),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _SwitchCard(
                      switchKey: const Key('show-ocr-engine-switch'),
                      title: 'Fiş detayında OCR motorunu göster',
                      subtitle: 'Fişin altında “İşleyen Motor: …” notunu gösterir.',
                      value: themeController.showOcrEngine,
                      onChanged: themeController.setShowOcrEngine,
                    ),
                    const _GroupHeader('Bildirimler ve Genel'),
                    const SectionLabel('Özet ekranı'),
                    const SizedBox(height: 8),
                    GroupedCard(
                      children: [
                        ListRow(
                          key: const ValueKey('home-layout-row'),
                          leading: IconTile(LucideIcons.layoutDashboard, size: 30, radius: 8),
                          title: 'Özet Görünümünü Özelleştir',
                          subtitle: themeController.hiddenHomeCards.isEmpty
                              ? 'Kartları aç/kapat ve sırala'
                              : '${themeController.hiddenHomeCards.length} kart gizli',
                          chevron: true,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const HomeLayoutPage()),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const SectionLabel('Bildirimler'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                      child: Text(
                        'Bütçe uyarıları (%80 / %100) ve sabit gider hatırlatıcıları yerel bildirim olarak gelir. '
                        'Bildirim iznini telefonun uygulama ayarlarından yönetebilirsin.',
                        key: const ValueKey('prefs-notifications-note'),
                        style: FissioText.body(c, size: 13, color: c.mute),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _InboundNotifySwitch(app: a),
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

/// Uygulama logosu: "temaya uygun" (vurgu rengini izler) ya da paletten sabit bir renk. Seçim başlatıcı
/// (ana ekran) ikonunu da değiştirir.
class _LogoSection extends StatelessWidget {
  const _LogoSection();

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: themeController, builder: (context, _) => _content(context));

  Widget _content(BuildContext context) {
    final c = context.c;
    final follows = themeController.logoFollowsTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupedCard(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const FissioLogo(size: 64),
                const SizedBox(width: 16),
                Expanded(
                  child: FutureBuilder<bool>(
                    future: themeController.launcherSupported,
                    builder: (context, snap) {
                      // Profil teması açıkken ana ekran ikonu ortak temayı izler; burada seçilen logo yalnız uygulama içidir.
                      final perProfile = themeController.perProfileTheme;
                      final icon = snap.data == true && !perProfile;
                      final what = icon ? 'Logo ve ana ekran ikonu' : 'Logo';
                      return Text(
                        '${follows ? '$what vurgu rengini izler.' : '$what seçtiğin sabit renkte kalır.'}'
                        '${perProfile ? ' Ana ekran ikonu profilden bağımsız, ortak temanın logosunu kullanır.' : icon ? '' : ' Ana ekran ikonu yalnızca yayın sürümünde değişir.'}',
                        style: FissioText.body(c, size: 14, color: c.mute).copyWith(height: 1.35),
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        SegmentedControl<bool>(
          key: const ValueKey('logo-mode'),
          value: follows,
          onChanged: (v) => themeController.setLogoColor(v ? null : themeController.logoColor),
          items: const [
            SegmentItem(true, 'Temaya uygun', icon: LucideIcons.sparkles),
            SegmentItem(false, 'Sabit renk', icon: LucideIcons.palette),
          ],
        ),
        if (!follows) ...[
          const SizedBox(height: 10),
          GroupedCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            children: [
              Wrap(
                alignment: WrapAlignment.spaceEvenly,
                runSpacing: 14,
                children: [
                  for (final o in kBrandPalette)
                    _Swatch(
                      key: ValueKey('logo-${o.key}'),
                      name: o.name,
                      color: o.color,
                      selected: themeController.logoColor.toARGB32() == o.color.toARGB32(),
                      onTap: () => themeController.setLogoColor(o.color),
                    ),
                ],
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 64,
          child: Column(
            children: [
              Container(
                width: 48,
                height: 48,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? c.ink : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Container(
                  decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                  child: selected
                      ? const Icon(LucideIcons.check, size: 20, color: Colors.white)
                      : null,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: FissioText.body(
                  c,
                  size: 11,
                  weight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? c.ink : c.mute,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tercihler'in üç ana grubunun belirgin başlığı (altındaki `SectionLabel`'lardan büyük, ince çizgi + üst boşluk).
/// Başlık + açıklama + anahtar satırı.
class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.switchKey,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final Key switchKey;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GroupedCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      children: [
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: FissioText.body(c, weight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: FissioText.body(c, size: 13, color: c.mute)),
                  ],
                ),
              ),
            ),
            Switch(key: switchKey, value: value, activeTrackColor: c.accent, onChanged: onChanged),
          ],
        ),
      ],
    );
  }
}

/// "Başarısız e-posta aktarımlarında e-posta ile bilgilendir": kullanıcı düzeyi, sunucuda saklanır (maili sunucu atar;
/// yalnız hesabın kayıtlı adresine). E-posta aktarımı kullanılamıyorsa (senkron kapalı / sunucuda kapalı) pasif.
class _InboundNotifySwitch extends StatefulWidget {
  const _InboundNotifySwitch({required this.app});
  final AppState app;

  @override
  State<_InboundNotifySwitch> createState() => _InboundNotifySwitchState();
}

class _InboundNotifySwitchState extends State<_InboundNotifySwitch> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_changed);
    if (widget.app.syncEnabled) widget.app.loadInboundNotifyFailures();
  }

  @override
  void dispose() {
    widget.app.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _set(bool v) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.app.setInboundNotifyFailures(v);
    } on ApiException catch (e) {
      if (mounted) showError(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.app;
    final available = a.emailImportAvailable;
    return _SwitchCard(
      switchKey: const Key('inbound-notify-switch'),
      title: 'Başarısız e-posta aktarımlarında e-posta ile bilgilendir',
      subtitle: available
          ? 'Yönlendirdiğin bir e-posta fişe dönüştürülemezse hesabının e-posta adresine nedenini bildiren kısa bir '
                'mail gelir (saatte en fazla 5). Gönderene asla yanıt verilmez.'
          : 'E-posta ile otomatik fiş aktarımı kullanılabilir olduğunda (bulut senkronu açık) ayarlanabilir.',
      value: a.inboundNotifyFailures ?? true,
      onChanged: available && !_busy ? _set : null,
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.title, {this.first = false});
  final String title;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: EdgeInsets.fromLTRB(4, first ? 0 : 34, 4, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            key: ValueKey('prefs-group-$title'),
            style: FissioText.title(c).copyWith(fontSize: 19),
          ),
          const SizedBox(height: 6),
          Container(height: 2, width: 28, color: c.accent),
        ],
      ),
    );
  }
}
