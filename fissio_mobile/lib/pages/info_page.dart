import 'package:flutter/material.dart';

import '../app_info.dart';
import '../logo.dart';
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
      'E-posta ile otomatik fiş aktarımı',
      'Bulut senkronu açıkken sana özel, tahmin edilemez bir yönlendirme adresi (…@fissio.dev) verilir. E-fatura, '
          'e-arşiv ve sipariş özeti maillerini bu adrese yönlendirdiğinde fişler kendiliğinden eklenir: ekteki UBL-TR XML '
          'fatura, PDF eki ya da mail gövdesi (ürün adı, adet ve tutarlarıyla) okunur. Aktarılan e-postaları '
          'Ayarlar > E-Posta ile Otomatik Fiş Aktarımı ekranındaki "Son Aktarılan E-Postalar" listesinden izleyebilirsin.',
    ),
    InfoSection(
      'Verilerin sende',
      'Fişlerini JSON veya CSV olarak dışa aktarabilir, yedekten geri yükleyebilirsin. Hesabını ve tüm verilerini '
          'dilediğin an kalıcı olarak silebilirsin.',
    ),
  ];

  /// Ayarlar ve kayıt ekranındaki onay penceresinde kullanılan başlıklar.
  static const privacyTitle = 'Gizlilik Politikası ve KVKK Aydınlatma Metni';
  static const termsTitle = 'Kullanım Şartları';

  /// Gizlilik Politikası ve 6698 sayılı KVKK m.10 kapsamında Aydınlatma Metni.
  static const privacy = <InfoSection>[
    InfoSection(
      'Veri sorumlusu ve iletişim',
      "Bu metin, 6698 sayılı Kişisel Verilerin Korunması Kanunu (KVKK) m.10 uyarınca hazırlanan aydınlatma metni ve "
          "Fissio'nun gizlilik politikasıdır. Kişisel verilerin veri sorumlusu sıfatıyla Fissio tarafından işlenir. "
          "Kişisel verilerinle ilgili tüm soru, talep ve başvuruların için veri sorumlusunun iletişim adresi: $supportEmail.",
    ),
    InfoSection(
      'Hangi verileri işliyoruz?',
      "Hesap bilgilerin: adın, e-posta adresin ve şifrenin geri döndürülemez biçimde hashlenmiş hâli (şifrenin kendisi "
          "saklanmaz). Profillerin ve profil fotoğrafların. Kaydettiğin fişlerin bilgileri: işletme/satıcı adı, tutar, "
          "tarih, kategori, fiş kalemleri (ürün adı ve tutarı), varsa belge numarası (ETTN), sipariş numarası ve notun. "
          "Fişe eklediğin fotoğraflar. Kategori düzeltmelerinden öğrenilen kuralların (satıcı/ürün adı → kategori). "
          "Bütçe limitlerin ve her ay tekrarlanan gider ayarların. Oturum ve cihaz bilgilerin (cihaz adı, platform, "
          "oturumun açıldığı IP adresi, son etkinlik zamanı). Sunucu istek kayıtları (log): isteğin IP adresi, zamanı "
          "ve çağrılan adres. E-posta ile fiş aktarımını açarsan: sana özel yönlendirme adresin ve aktarım geçmişin. "
          "Aktarım geçmişinde YALNIZCA gönderici, konu, alınma tarihi, işlem durumu (ör. kaydedildi, yok sayıldı, "
          "başarısız), varsa hata nedeni ve oluşturulan fişin bağlantısı tutulur; ham e-posta gövdesi ve ekleri (XML, "
          "PDF, HTML) hiçbir zaman saklanmaz. Uygulamada reklam veya kullanıcı takibi yapılmaz; reklam ya da analitik "
          "amaçlı üçüncü taraf yazılım kullanılmaz. Cihaz içi metin okuma Google ML Kit kütüphanesiyle yapılır: fiş "
          "fotoğrafı cihazından çıkmaz, ancak Google kütüphanenin çalışmasına ilişkin anonim kullanım ve performans "
          "ölçümleri toplayabilir.",
    ),
    InfoSection(
      'Verileri nasıl topluyoruz?',
      'Kişisel verilerin; uygulamadaki formlara girdiğin bilgilerden, kamera veya galeriden eklediğin fiş '
          'fotoğraflarından, paylaştığın ya da içe aktardığın dosyalardan (PDF, e-posta, JSON/CSV yedek) ve sana özel '
          'adrese yönlendirdiğin e-postalardan, kısmen otomatik yollarla (OCR ile metin okuma, fiş/fatura ayrıştırma ve '
          'otomatik kategori önerisi) toplanır.',
    ),
    InfoSection(
      'İşleme amaçları ve hukuki sebepler',
      'Verilerin; hesabının oluşturulması ve doğrulanması, fişlerinin okunması, kaydedilmesi, kategorilere ayrılması '
          've raporlanması, bütçe ve ödeme hatırlatmalarının sunulması, verilerinin cihazların arasında senkronize '
          'edilmesi amacıyla KVKK m.5/2-c (sözleşmenin kurulması ve ifası) hukuki sebebine; hesap ve oturum güvenliğinin '
          'sağlanması, kötüye kullanımın önlenmesi (ör. hız sınırları, şüpheli oturumların kapatılması, IP adresi ve '
          'sunucu istek kayıtları) amacıyla m.5/2-f '
          '(meşru menfaat) hukuki sebebine; yetkili makamların hukuka uygun talepleri hâlinde m.5/2-ç (hukuki '
          'yükümlülük) hukuki sebebine dayanılarak işlenir. Verilerin pazarlama veya profilleme amacıyla kullanılmaz.',
    ),
    InfoSection(
      'Bulut senkronizasyonu ve cihazda saklama',
      "Bulut senkronizasyonu açıkken (varsayılan) verilerin hesabına bağlı olarak sunucu veritabanında saklanır ve "
          "yalnızca senin hesabınla erişilebilir; başka hesapların profillerine ve fişlerine erişim mümkün değildir. "
          "Senkronizasyonu Ayarlar > Veri Yönetimi'nden dilediğin an kapatabilirsin; kapalıyken ya da çevrimdışıyken "
          "kaydettiklerin yalnızca cihazında tutulur ve sunucuya hiçbir şey yazılmaz. Senkronizasyonu yeniden "
          "açtığında bekleyen kayıtların yüklenir.",
    ),
    InfoSection(
      'Fiş fotoğrafları ve OCR',
      "Sunucu OCR'ı kullanıldığında fotoğraf, metne çevrilmek üzere geçici olarak sunucuya gönderilir ve bu "
          "işlem sırasında kalıcı olarak saklanmaz. Cihaz içi OCR'da (senkronizasyon kapalıyken her zaman) fotoğraf "
          "cihazından çıkmaz. Fişe eklediğin fotoğraflar yalnızca kaydetmeyi seçersen ve senkronizasyon açıksa "
          "bulutta tutulur.",
    ),
    InfoSection(
      'E-posta kullanımı',
      'E-posta adresin hesap doğrulama, şifre sıfırlama ve güvenlik amaçlı kodları göndermek için kullanılır; '
          'pazarlama amacıyla kullanılmaz ve üçüncü kişilerle paylaşılmaz.',
    ),
    InfoSection(
      'E-posta ile fiş aktarımı',
      'İstersen sana özel @fissio.dev yönlendirme adresini açarsın; bu adrese gelen e-postalar YALNIZCA fiş/fatura '
          'ayrıştırma amacıyla işlenir (tutar, tarih, işletme ve kalemler çıkarılır). Mail gövdesi ve ekleri (XML/PDF/HTML) '
          'kaydedilmez; saklanan yalnızca ortaya çıkan fiş verisi ile "Son Aktarılan E-Postalar" geçmişidir: gönderici, '
          'konu, tarih, durum, varsa hata nedeni ve ilgili fiş (son 50 kayıt). Gmail yönlendirme onay maili fiş sayılmaz; '
          'onay kodu/bağlantısı yalnızca kurulum için kısa süre tutulur. Adresin sızdığını düşünürsen "Adresi yenile" ile '
          'eskisini anında geçersiz kılabilir, aktarımı istediğin an duraklatabilirsin. Adres, geçmiş ve aktarılan fişler '
          'hesabını sildiğinde de kalıcı olarak silinir. Senkron kapalıyken adres kullanılamaz.',
    ),
    InfoSection(
      'Verilerin aktarılması',
      'Kişisel verilerin satılmaz, kiralanmaz ve reklam amacıyla paylaşılmaz. Yalnızca hizmetin sunulması için gerekli '
          'olduğu ölçüde ve bu amaçla sınırlı olarak altyapı hizmet sağlayıcılarına aktarılır: sunucu ve veritabanı '
          'barındırma hizmeti; doğrulama ve şifre sıfırlama kodlarını gönderen e-posta gönderim (SMTP) hizmeti (e-posta '
          'adresin ve kod); yönlendirdiğin e-postaları Fissio\'ya ileten e-posta yönlendirme hizmeti (mail yalnızca '
          'iletim sırasında bu hizmetten geçer). Bu sağlayıcıların sunucuları yurt dışında bulunabilir; yurt dışına '
          'aktarım KVKK m.9\'daki şartlara uygun olarak yapılır. Ayrıca yetkili kamu kurum ve kuruluşlarının hukuka '
          'uygun talepleri hâlinde, kanunen zorunlu olan ölçüde paylaşılabilir.',
    ),
    InfoSection(
      'Saklama süresi',
      'Verilerin hesabın açık kaldığı sürece saklanır. E-posta aktarım geçmişinde en fazla son 50 kayıt tutulur; daha '
          'eskileri kendiliğinden silinir. Doğrulama kodları kısa süre (dakikalar) sonra geçersiz olur. Oturum '
          'kayıtları (IP adresi dahil) oturum kapatıldıktan sonra da güvenlik geçmişi olarak hesabın açık kaldığı '
          'sürece tutulur ve hesap silinince silinir; sunucu istek kayıtlarına '
          'yalnızca hizmet işletmecisi erişir ve bunlar güvenlik amacıyla sınırlı bir süre tutulduktan sonra silinir. Hesabını '
          'sildiğinde hesabın, profillerin, fişlerin, fotoğrafların, öğrenilen kuralların, bütçelerin, yönlendirme '
          'adresin ve aktarım geçmişin sunucudan kalıcı olarak silinir ve tüm oturumların kapatılır.',
    ),
    InfoSection(
      'Haklarınız (KVKK / GDPR)',
      "KVKK m.11 uyarınca; kişisel verilerinin işlenip işlenmediğini öğrenme, işlenmişse buna ilişkin bilgi talep etme, "
          "işlenme amacını ve amacına uygun kullanılıp kullanılmadığını öğrenme, yurt içinde veya yurt dışında "
          "aktarıldığı üçüncü kişileri bilme, eksik veya yanlış işlenmişse düzeltilmesini isteme, KVKK m.7 çerçevesinde "
          "silinmesini veya yok edilmesini isteme, bu düzeltme ve silme işlemlerinin verilerin aktarıldığı üçüncü kişilere "
          "bildirilmesini isteme, işlenen verilerin münhasıran otomatik sistemler vasıtasıyla analiz edilmesi (ör. "
          "otomatik kategori önerisi ve öğrenilen kurallar) suretiyle aleyhine bir sonucun ortaya çıkmasına itiraz etme "
          "ve kanuna aykırı işleme sebebiyle zarara uğraman hâlinde zararın giderilmesini talep etme haklarına "
          "sahipsin. Verilerini uygulama içinden JSON/CSV olarak dışa aktarabilir, kaydettiğin bilgileri dilediğin an "
          "düzeltebilirsin. Ayarlar > Hesap > \"Hesabımı kalıcı olarak sil\" ile hesabın ve tüm verilerin sunucudan ve "
          "bu cihazdan kalıcı olarak silinir; bu işlem geri alınamaz. Başvurularını $supportEmail adresine "
          "iletebilirsin; talebin en geç 30 gün içinde ücretsiz olarak sonuçlandırılır. Başvurunun reddedilmesi, "
          "verilen cevabı yetersiz bulman veya süresinde cevap verilmemesi hâlinde KVKK m.14 uyarınca Kişisel Verileri "
          "Koruma Kurulu'na şikâyette bulunabilirsin.",
    ),
    InfoSection(
      'Güvenlik',
      "Üretim ortamında iletişim HTTPS ile şifrelenir; oturum anahtarların cihazında güvenli depolamada tutulur, "
          "şifren hiçbir zaman cihazında saklanmaz. Uzaktan oturum kapatma Ayarlar > Aktif oturumlar'dan yapılabilir.",
    ),
    InfoSection(
      'Değişiklikler',
      'Bu metin, hizmette veya mevzuatta değişiklik oldukça güncellenebilir; güncel sürüm her zaman uygulamada '
          'Ayarlar > Gizlilik Politikası altında yer alır.',
    ),
  ];

  static const terms = <InfoSection>[
    InfoSection(
      'Hizmetin amacı',
      'Fissio, YALNIZCA kişisel finans ve harcama takibi amacıyla sunulan bir uygulamadır. Ticari muhasebe, defter '
          'tutma, vergi beyannamesi hazırlama veya resmi kayıt aracı değildir ve bu amaçlarla kullanılmamalıdır.',
    ),
    InfoSection(
      'Kullanım',
      'Fissio\'yu kullanarak bu şartları kabul etmiş olursun. Hesabını yalnızca kendin kullanır, doğru ve güncel '
          'bilgiler verirsin. Okunan fiş verileri otomatik olarak çıkarılır ve hatalı olabilir; kaydetmeden önce kontrol '
          'etmek sana aittir.',
    ),
    InfoSection(
      'Otomatik okuma sonuçları bilgi amaçlıdır',
      'Fiş fotoğraflarından OCR ile, e-faturalardan UBL-TR XML ayrıştırmasıyla ve e-posta/PDF içeriklerinden HTML/metin '
          'ayrıştırmasıyla elde edilen tutar, tarih, satıcı, kalem, KDV ve kategori bilgileri YALNIZCA bilgi amaçlıdır; '
          'eksik veya hatalı olabilir. Bu sonuçlar vergi, muhasebe veya hukuki işlemlerde resmi belge yerine geçmez; '
          'geçerli olan her zaman satıcının düzenlediği asıl fatura/fiştir. Otomatik sonuçlara dayanılarak verilen '
          'kararlardan Fissio sorumlu tutulamaz.',
    ),
    InfoSection(
      'Kullanıcının yükümlülükleri',
      'Uygulamaya yalnızca KENDİNE ait, hukuka uygun olarak düzenlenmiş fatura ve fişleri yükleyebilir ve '
          'yönlendirebilirsin; bunu yapmakla yükümlüsün. Başkalarına ait kişisel verileri içeren belgeleri, sahte veya '
          'hukuka aykırı içerikleri gönderemezsin. Asıl (orijinal) belgelerini, yasal saklama süreleri boyunca kendin '
          'saklamaktan sorumlusun; Fissio bir belge arşivleme hizmeti değildir.',
    ),
    InfoSection(
      'E-posta yönlendirme',
      'Yönlendirme adresine yalnızca kendi fiş ve faturalarını ilet; başkalarına ait kişisel verileri içeren mailleri '
          'göndermemelisin. Gmail/Outlook filtresini ve yönlendirmeyi sen kurar ve yönetirsin; adresin gizliliği sana '
          'aittir. Otomatik okunan fişler hatalı olabilir; kaydedilen tutar, tarih ve kalemleri kontrol etmek sana aittir.',
    ),
    InfoSection(
      'Sorumluluk',
      'Uygulama resmi bir muhasebe, fatura veya vergi belgesi yerine geçmez. Hizmet "olduğu gibi" sunulur; kesintisiz '
          'veya hatasız çalışacağı garanti edilmez. Verilerini düzenli olarak dışa aktarman önerilir. Hesabının '
          'güvenliğinden ve şifrenin gizliliğinden sen sorumlusun.',
    ),
    InfoSection(
      'Hesabın sonlandırılması',
      'Hesabını Ayarlar > Hesap üzerinden dilediğin an kalıcı olarak silebilirsin. Bu şartların veya hukukun ağır '
          'ihlali, hizmetin kötüye kullanılması ya da güvenliği tehdit eden kullanım hâlinde hesap askıya alınabilir.',
    ),
    InfoSection(
      'Değişiklikler ve iletişim',
      'Bu şartlar güncellenebilir; güncel sürüm her zaman uygulamada yer alır. Sorularını $supportEmail adresine '
          'iletebilirsin.',
    ),
  ];
}

/// Başlıklı paragraf listesi (Bilgi sayfaları ve kayıt ekranındaki yasal onay penceresi).
class InfoSectionsList extends StatelessWidget {
  const InfoSectionsList({super.key, required this.sections});
  final List<InfoSection> sections;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
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
    );
  }
}

class InfoPage extends StatelessWidget {
  const InfoPage({super.key, required this.title, required this.sections, this.showLogo = false});
  final String title;
  final List<InfoSection> sections;

  /// "Hakkımızda": başlığın altında logo + uygulama adı.
  final bool showLogo;

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
                  if (showLogo)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 22),
                      child: Align(alignment: Alignment.centerLeft, child: FissioWordmark(logoSize: 56, fontSize: 40)),
                    ),
                  InfoSectionsList(sections: sections),
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
