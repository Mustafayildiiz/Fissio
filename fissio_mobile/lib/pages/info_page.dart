import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';

class InfoTexts {
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
