import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';

/// Bilgi sayfalarındaki başlıklı paragraf.
class InfoSection {
  const InfoSection(this.heading, this.body);
  final String heading;
  final String body;
}

class InfoTexts {
  static const about = <InfoSection>[
    InfoSection(
      'Fissio nedir?',
      'Fissio, fişlerinizi fotoğraftan okuyup kaydetmenize ve mikro harcamalarınızı kategori bazında '
          'takip etmenize yardımcı olan bir harcama yönetim uygulamasıdır.',
    ),
    InfoSection(
      'Hesap ve profiller',
      'Uygulama e-posta doğrulamalı bir hesapla çalışır. Her hesabın kendi profilleri vardır (ör. Kişisel, Ev, İş); '
          'fişler ve raporlar profil bazında tutulur, öğrenilen kategori tercihlerin hesabına özeldir ve hesaplar birbirinden tamamen yalıtılmıştır.',
    ),
    InfoSection(
      'Bulut ve çevrimdışı kullanım',
      'Bulut senkronizasyonu varsayılan olarak açıktır; verilerin hesabına bağlı olarak yedeklenir ve cihazlar '
          'arasında erişilebilir olur. İstersen Ayarlar > Veri Yönetimi\'nden senkronu kapatıp yalnızca bu cihazda '
          'çalışabilirsin. Bağlantı yokken de fiş tarayabilir ve kaydedebilirsin; kayıtlar bağlantı gelince '
          'otomatik yüklenir.',
    ),
    InfoSection(
      'Fiş okuma',
      'Fişler, bağlantı ve ayarlara göre sunucudaki yüksek doğruluklu OCR servisiyle ya da cihaz içi OCR ile '
          'okunur. Okunan alanları kaydetmeden önce her zaman kontrol edip düzeltebilirsin.',
    ),
    InfoSection(
      'Verilerin sende',
      'Fişlerini JSON veya CSV olarak dışa aktarabilir, yedekten geri yükleyebilirsin. Hesabını ve tüm verilerini '
          'dilediğin an kalıcı olarak silebilirsin.',
    ),
  ];

  static const privacy = <InfoSection>[
    InfoSection(
      'Hangi verileri işliyoruz?',
      'Hesap bilgilerin (e-posta adresi, adın ve şifrenin geri döndürülemez biçimde hashlenmiş hâli), '
          'profillerin, kaydettiğin fişlerin finansal bilgileri (işletme, tutar, tarih, kategori, kalemler), '
          'fiş fotoğrafların, profil fotoğrafların ve oturum/cihaz bilgilerin (cihaz adı, platform, son etkinlik).',
    ),
    InfoSection(
      'Nerede saklanır?',
      'Bulut senkronizasyonu açıkken (varsayılan) veriler hesabına bağlı olarak sunucu veritabanında saklanır ve '
          'yalnızca senin hesabınla erişilebilir; başka hesapların profillerine ve fişlerine erişim mümkün değildir. '
          'Senkronizasyon kapalıyken ya da çevrimdışıyken kaydettiklerin yalnızca cihazında tutulur; yeniden '
          'etkinleştirdiğinde yüklenir.',
    ),
    InfoSection(
      'Fiş fotoğrafları ve OCR',
      'Sunucu OCR\'ı kullanıldığında fotoğraf, metne çevrilmek üzere geçici olarak sunucuya gönderilir ve bu '
          'işlem sırasında kalıcı olarak saklanmaz. Cihaz içi OCR\'da fotoğraf cihazından çıkmaz. Fişe eklediğin '
          'fotoğraflar yalnızca kaydetmeyi seçersen ve senkronizasyon açıksa bulutta tutulur.',
    ),
    InfoSection(
      'E-posta kullanımı',
      'E-posta adresin hesap doğrulama, şifre sıfırlama ve güvenlik amaçlı kodları göndermek için kullanılır; '
          'pazarlama amacıyla kullanılmaz ve üçüncü kişilerle paylaşılmaz.',
    ),
    InfoSection(
      'Haklarınız (KVKK / GDPR)',
      'Verilerine erişme, düzeltme, dışa aktarma (JSON/CSV) ve silme hakkına sahipsin. Ayarlar > Hesap > '
          '"Hesabımı kalıcı olarak sil" ile hesabın, profillerin, fişlerin, fotoğrafların ve açık oturumların '
          'sunucudan ve bu cihazdan kalıcı olarak silinir; bu işlem geri alınamaz. Talepleriniz için Destek '
          'ekranındaki adresten bize ulaşabilirsiniz.',
    ),
    InfoSection(
      'Güvenlik',
      'Üretim ortamında iletişim HTTPS ile şifrelenir; oturum anahtarların cihazında güvenli depolamada tutulur, '
          'şifren hiçbir zaman cihazında saklanmaz. Uzaktan oturum kapatma Ayarlar > Aktif oturumlar\'dan yapılabilir.',
    ),
  ];

  static const terms = <InfoSection>[
    InfoSection(
      'Kullanım',
      'Fissio, kişisel harcama takibi için sunulur. Okunan fiş verileri otomatik olarak çıkarılır ve hatalı '
          'olabilir; kaydetmeden önce kontrol etmek sana aittir.',
    ),
    InfoSection(
      'Sorumluluk',
      'Uygulama resmi bir muhasebe, fatura veya vergi belgesi yerine geçmez. Hesabının güvenliğinden ve '
          'şifrenin gizliliğinden sen sorumlusun.',
    ),
  ];
}

class InfoPage extends StatelessWidget {
  const InfoPage({super.key, required this.title, required this.sections});
  final String title;
  final List<InfoSection> sections;

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
              child: Text(title, style: FissioText.title(c)),
            ),
            const Rule2(margin: EdgeInsets.fromLTRB(20, 16, 20, 8)),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                  for (final s in sections)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.heading, style: FissioText.body(c, size: 16, weight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          Text(s.body, style: FissioText.body(c, size: 15).copyWith(height: 1.5)),
                        ],
                      ),
                    ),
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
