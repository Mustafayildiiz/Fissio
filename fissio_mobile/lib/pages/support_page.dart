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

/// E-posta ile fiş aktarımında karşılaşılabilecek olumsuz senaryolar ve çözümleri (Ayarlar > E-Posta ile Otomatik Fiş Aktarımı).
const _emailFaqs = <_Faq>[
  _Faq(
    'Gmail yönlendirme onay maili gelmedi / kod görünmüyor.',
    'Önce Gmail\'de "Yönlendirme adresi ekle" ile Fissio adresini girdiğinden emin ol. Google\'ın onay maili birkaç dakika '
        'gecikebilir; Fissio ekranı açıkken her 5 saniyede bir kontrol eder ve kod/onay bağlantısı kendiliğinden görünür '
        '(24 saat geçerlidir). Hâlâ gelmediyse adresi yazım hatası için kontrol et, Gmail\'de Gönderilmiş/Spam klasörüne bak '
        've gerekirse Fissio\'da "Adresi Yenile" ile yeni adres üretip yönlendirmeyi yeni adresle yeniden ekle.',
  ),
  _Faq(
    'Mail gönderildi ama "Tutar Bulunamadı" göründü.',
    'Fissio e-postadaki METNİ okur. Yalnızca görsel içeren mailler ya da taranmış (resim) PDF\'ler metne dönüştürülemediği için '
        'tutar bulunamaz ve sunucuda OCR\'a gönderilmez. Çözüm: e-Arşiv XML ya da metin katmanlı PDF eki olan faturayı ilet; '
        'olmuyorsa PDF\'i mail uygulamandan Paylaş → Fissio ile ekle ya da fişi kamerayla tara.',
  ),
  _Faq(
    'Aynı fatura iki kez gelirse ne olur?',
    'Fissio mükerrer kaydı engeller: ETTN / fatura numarası, sipariş numarası ya da mail içeriği aynıysa ikinci mail yeni fiş '
        'oluşturmaz; geçmişte "Zaten Kayıtlı" olarak görünür. Siparişin özeti ile resmi faturası ayrı gelirse tek fişte birleşir.',
  ),
  _Faq(
    'Yabancı para birimli (USD/EUR) veya desteklenmeyen faturalar.',
    'Şu an yalnızca TL (TRY) faturalar işlenir. USD/EUR gibi faturalar otomatik kaydedilmez; bunları Yeni fiş > Manuel ile '
        'TL karşılığıyla ekleyebilirsin.',
  ),
  _Faq(
    'Adresim spam listesine düştü ya da gereksiz reklam mailleri geliyor.',
    'Gmail filtresini daralt: Fissio\'daki hazır filtre sorgusu yalnızca fatura, fiş, sipariş, makbuz, ödeme ve bilet '
        'maillerini yakalar, bülten/kampanya/indirim mailleri dışarıda kalır. Geçici olarak durdurmak için '
        '"Aktarımı duraklat" anahtarını kullan (adres ve geçmişin korunur). Adres başkalarının eline geçtiyse "Adresi Yenile" '
        'ile tek dokunuşla yeni bir @fissio.dev adresi üret; eski adres hemen geçersiz olur.',
  ),
  _Faq(
    'E-posta aktarımını tamamen kapatmak istiyorum.',
    '1) Fissio\'da E-Posta ile Otomatik Fiş Aktarımı ekranından "Aktarımı duraklat"ı aç: gelen mailler fişe dönüşmez. '
        '2) Gmail\'de Ayarlar → Tüm ayarlar → Yönlendirme ve POP/IMAP bölümünde Fissio adresini kaldır ve Filtreler ve engellenen '
        'adresler sekmesinden Fissio\'ya ileten filtreyi sil. Daha önce kaydedilen fişlerin korunur.',
  ),
  _Faq(
    'Gönderim 5.7.1 / "teslim edilemedi" hatası aldım.',
    'Bu bildirim Gmail/Outlook\'un maili Fissio adresine iletemediğini söyler. Sık nedenler: 1) Mail ya da ekleri çok büyük '
        '(yaklaşık 15 MB üstü) — ek boyutunu küçült ya da PDF\'i mail uygulamasından "Paylaş → Fissio ile ekle" ile cihazda işle. '
        '2) Adres yenilendi ya da yazım hatası var — E-Posta ile Otomatik Fiş Aktarımı ekranındaki güncel adresi kopyalayıp '
        'yönlendirmeyi yeniden ekle. 3) Mail sağlayıcın güvenlik politikası nedeniyle dış adrese iletmeyi engelliyor '
        '(kurumsal hesaplarda sık) — kişisel bir hesaptan ilet. 4) Gönderen alan adı kimlik doğrulamasından (SPF/DKIM/DMARC) '
        'geçemedi — bu, faturayı gönderen firmanın posta ayarlarından kaynaklanır; faturayı Paylaş → Fissio ile ekle. '
        'Büyük mail kaydedilmez ama kendi kutunda durur ve E-Posta ekranındaki geçmişte "Çok Büyük" olarak görünür; '
        'fişini yine Paylaş → Fissio ile ekleyebilirsin.',
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
                  const SizedBox(height: 12),
                  const SectionLabel('E-posta ile fiş aktarımı'),
                  GroupedCard(
                    key: const ValueKey('support-email-faqs'),
                    children: [
                      for (final f in _emailFaqs) _FaqTile(f),
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
