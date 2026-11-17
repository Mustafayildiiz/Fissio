import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_info.dart';
import '../theme.dart';
import '../widgets.dart';

class _Faq {
  const _Faq(this.q, this.a);
  final String q;
  final String a;
}

const _faqs = <_Faq>[
  _Faq(
    'Fişim hatalı okunuyor, ne yapmalıyım?',
    'Fişi düz bir yüzeyde, iyi ışıkta ve tamamını kadraja alarak çek; kırışık veya yansımalı fişlerde okuma '
        'zorlaşır. Uzun fişleri en fazla 6 sayfa halinde, üst üste binen kısımlarla çekebilirsin. Okunan tutar ve '
        'kalemleri kaydetmeden önce form ekranında düzeltebilirsin.',
  ),
  _Faq(
    'İnternet yokken fiş ekleyebilir miyim?',
    'Evet. Bağlantı yokken fiş cihaz içi OCR ile okunur ve cihazda saklanır; bağlantı gelince, bulut '
        'senkronizasyonu açıksa otomatik olarak yüklenir.',
  ),
  _Faq(
    'Bulut senkronizasyonu nedir, kapatırsam ne olur?',
    'Senkronizasyon açıkken fişlerin ve profillerin hesabına yedeklenir. Ayarlar > Veri Yönetimi\'nden '
        'kapatırsan yeni kayıtlar yalnızca bu cihazda kalır; tekrar açınca cihazdaki kayıtlar yüklenir.',
  ),
  _Faq(
    'Verilerimi nasıl dışa veya içe aktarırım?',
    'Ayarlar > Veri Yönetimi\'nden fişlerini JSON veya CSV olarak dışa aktarabilir, JSON yedeğinden ya da '
        'CSV\'den içe aktarabilirsin. Aynı kayıtlar tekrar eklenmez.',
  ),
  _Faq(
    'Hesabımı ve verilerimi nasıl silerim?',
    'Ayarlar > Hesap > "Hesabımı kalıcı olarak sil" seçeneğiyle, şifreni onaylayarak hesabını, profillerini, '
        'fişlerini ve fotoğraflarını kalıcı olarak silebilirsin. İşlem geri alınamaz.',
  ),
  _Faq(
    'Doğrulama kodu gelmedi.',
    'Gelen kutusu ve spam klasörünü kontrol et. Kod 10 dakika geçerlidir; 60 saniye sonra yeniden '
        'gönderebilirsin.',
  ),
];

/// Destek ekranı: tek dokunuşla e-posta, SSS ve sürüm bilgisi.
class SupportPage extends StatefulWidget {
  const SupportPage({super.key});

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    appVersionLoader().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  Future<void> _mail() async {
    final ok = await mailLauncher(supportMailUri(version: _version));
    if (ok) return;
    await clipboardWriter(supportEmail);
    if (mounted) showMessage(context, 'E-posta uygulaması açılamadı. Adres panoya kopyalandı.');
  }

  Future<void> _copy() async {
    await clipboardWriter(supportEmail);
    if (mounted) showMessage(context, 'Destek adresi kopyalandı.');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const NavBackBar(label: 'Ayarlar'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text('Destek', style: FissioText.title(c)),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  GroupedCard(
                    children: [
                      ListRow(
                        key: const ValueKey('support-mail'),
                        leading: IconTile(LucideIcons.mail, size: 34, radius: 10),
                        title: 'Destek ekibine yaz',
                        subtitle: supportEmail,
                        chevron: true,
                        onTap: _mail,
                      ),
                      ListRow(
                        key: const ValueKey('support-copy'),
                        leading: IconTile(LucideIcons.copy, size: 34, radius: 10),
                        title: 'Adresi kopyala',
                        onTap: _copy,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const SectionLabel('Sıkça sorulan sorular'),
                  GroupedCard(
                    children: [
                      for (final f in _faqs)
                        _FaqTile(f),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 18, 4, 0),
                    child: Text(
                      _version.isEmpty ? 'Fissio' : 'Fissio · Sürüm $_version',
                      key: const ValueKey('support-version'),
                      style: FissioText.body(c, size: 13, color: c.mute),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kartın içinde açılıp kapanan SSS satırı (ExpansionTile, renkli kart içinde ListTile uyarısı verir).
class _FaqTile extends StatefulWidget {
  const _FaqTile(this.faq);
  final _Faq faq;

  @override
  State<_FaqTile> createState() => _FaqTileState();
}

class _FaqTileState extends State<_FaqTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: Row(
              children: [
                Expanded(child: Text(widget.faq.q, style: FissioText.body(c, weight: FontWeight.w600))),
                const SizedBox(width: 8),
                Icon(_open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 16, color: c.mute),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(widget.faq.a, style: FissioText.body(c, size: 14, color: c.mute).copyWith(height: 1.5)),
          ),
      ],
    );
  }
}
