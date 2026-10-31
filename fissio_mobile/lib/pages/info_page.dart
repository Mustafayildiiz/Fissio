import 'package:flutter/material.dart';

import '../widgets.dart';

class InfoTexts {
  static const settings = 'Uygulama ayarları (tema, para birimi, bildirimler) sonraki sürümlerde eklenecek.';
  static const data = 'Harcama kayıtlarınız hesabınıza bağlı olarak veritabanında saklanır. '
      'Fiş fotoğrafları sunucuya yüklenmez ve saklanmaz.';
  static const support = 'Sorun ve önerileriniz için proje deposundaki Issues bölümünü kullanabilirsiniz.';
  static const about = 'Fissio, fişlerinizi kaydetmenize ve mikro harcamalarınızı '
      'kategori bazında takip etmenize yardımcı olan bir harcama yönetim uygulamasıdır.';
  static const privacy = 'Fiş görselleri cihazda işlenir ve sunucuya gönderilmez. '
      'Yalnızca onayladığınız finansal kayıtlar (marka, tutar, tarih, kategori) saklanır. '
      'Şifreniz bcrypt ile hashlenerek tutulur.';
  static const terms = 'Bu uygulama ders projesi kapsamında geliştirilmiştir. '
      'Resmi bir muhasebe belgesi yerine geçmez.';
}

class InfoPage extends StatelessWidget {
  const InfoPage({super.key, required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BackTitle(title),
            Padding(
              padding: const EdgeInsets.all(20),
              child: DarkCard(
                child: Text(
                  body,
                  style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

