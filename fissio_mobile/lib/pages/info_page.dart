import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';

class InfoTexts {
  static const data = 'Fişlerin ve profillerin varsayılan olarak hesabına bağlı biçimde bulutta (sunucu veritabanında) '
      'saklanır; bağlantı yokken kaydettiklerin cihazda bekler ve bağlantı gelince otomatik yüklenir. '
      'Ayarlar > Veri Yönetimi\'nden bulut senkronunu kapatırsan yeni kayıtlar yalnızca bu cihazda kalır. '
      'Verilerini JSON veya CSV olarak dışa aktarabilir, yedekten geri yükleyebilirsin.';
  static const support = 'Sorun ve önerileriniz için proje deposundaki Issues bölümünü kullanabilirsiniz.';
  static const about = 'Fissio, fişlerinizi kaydetmenize ve mikro harcamalarınızı '
      'kategori bazında takip etmenize yardımcı olan bir harcama yönetim uygulamasıdır.';
  static const privacy = 'Fiş fotoğrafı, metne çevrilmek üzere işlenmesi için geçici olarak sunucuya gönderilir ve '
      'bu işlem sırasında saklanmaz. Kaydettiğin fişlerin fotoğrafları ve finansal kayıtlar (işletme, tutar, tarih, '
      'kategori, kalemler) hesabına bağlı olarak saklanır; bulut senkronu kapalıyken yalnızca cihazında kalır. '
      'Şifren bcrypt ile hashlenerek tutulur. Hesabını Ayarlar\'dan kalıcı olarak silersen tüm verilerin silinir.';
  static const terms = 'Bu uygulama ders projesi kapsamında geliştirilmiştir. '
      'Resmi bir muhasebe belgesi yerine geçmez.';
}

class InfoPage extends StatelessWidget {
  const InfoPage({super.key, required this.title, required this.body});
  final String title;
  final String body;

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
            const Rule2(margin: EdgeInsets.fromLTRB(20, 16, 20, 16)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GroupedCard(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    body,
                    style: FissioText.body(c, size: 15).copyWith(height: 1.5),
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
