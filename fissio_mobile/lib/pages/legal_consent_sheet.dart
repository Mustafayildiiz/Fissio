import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';
import '../widgets.dart';
import 'account_widgets.dart';
import 'info_page.dart';

/// Kayıt ekranındaki yasal onay penceresi. Metin sonuna kadar kaydırılmadan (metin ekrana sığıyorsa hemen)
/// "Okudum, Kabul Ediyorum" düğmesi pasif kalır. Kabul edilirse `true`, kapatılırsa `false` döner.
Future<bool> showLegalConsent(
  BuildContext context, {
  required String title,
  required List<InfoSection> sections,
}) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Metni kaydırma hareketi pencereyi kapatmasın; kapatma = X düğmesi / geri.
    enableDrag: false,
    backgroundColor: context.c.bg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: LegalConsentSheet(title: title, sections: sections),
    ),
  );
  return accepted == true;
}

class LegalConsentSheet extends StatefulWidget {
  const LegalConsentSheet({super.key, required this.title, required this.sections});
  final String title;
  final List<InfoSection> sections;

  @override
  State<LegalConsentSheet> createState() => _LegalConsentSheetState();
}

class _LegalConsentSheetState extends State<LegalConsentSheet> {
  /// Sona bu kadar piksel kala "okundu" sayılır (yuvarlama / alt boşluk payı).
  static const _endTolerance = 8.0;

  final _scroll = ScrollController();
  bool _reachedEnd = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_check);
    // İlk yerleşimden sonra: metin ekrana sığıyorsa düğme hemen aktif olur.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _scroll.removeListener(_check);
    _scroll.dispose();
    super.dispose();
  }

  void _check() {
    if (_reachedEnd || !mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (!p.hasContentDimensions) return;
    if (p.maxScrollExtent <= 0 || p.pixels >= p.maxScrollExtent - _endTolerance) {
      setState(() => _reachedEnd = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(widget.title, style: FissioText.body(c, size: 20, weight: FontWeight.w800)),
                ),
              ),
              IconButton(
                key: const ValueKey('legal-close'),
                tooltip: 'Kapat',
                icon: Icon(LucideIcons.x, color: c.mute),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
        const Rule2(margin: EdgeInsets.fromLTRB(20, 12, 20, 0)),
        Expanded(
          // Pencere boyutu değişirse (döndürme, yazı boyutu) "sığıyor mu" yeniden değerlendirilir.
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _check());
              return false;
            },
            child: SingleChildScrollView(
              key: const ValueKey('legal-scroll'),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: InfoSectionsList(sections: widget.sections),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_reachedEnd)
                Padding(
                  key: const ValueKey('legal-scroll-hint'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Onaylamak için metni sonuna kadar kaydır.',
                    textAlign: TextAlign.center,
                    style: FissioText.body(c, size: 13, color: c.mute),
                  ),
                ),
              ArrowButton(
                key: const ValueKey('legal-accept'),
                label: 'Okudum, Kabul Ediyorum',
                onPressed: _reachedEnd ? () => Navigator.of(context).pop(true) : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
