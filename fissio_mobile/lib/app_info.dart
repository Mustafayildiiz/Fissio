import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Destek ve veri sorumlusu iletişim adresi (Destek ekranı, Gizlilik Politikası / KVKK metni ve Kullanım Şartları).
const supportEmail = 'destek@fissio.dev';

/// Uygulama sürümü ("1.0.0 (1)"). Testlerde değiştirilebilir; okunamazsa boş döner.
Future<String> Function() appVersionLoader = () async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.buildNumber.isEmpty ? info.version : '${info.version} (${info.buildNumber})';
  } catch (_) {
    return '';
  }
};

/// `mailto:` açar; açılamazsa false döner (çağıran adresi panoya kopyalar). Testlerde değiştirilebilir.
Future<bool> Function(Uri uri) mailLauncher = (uri) async {
  try {
    return await launchUrl(uri);
  } catch (_) {
    return false;
  }
};

/// Harici bir bağlantıyı (ör. Gmail yönlendirme onayı) tarayıcıda açar; açılamazsa false. Testlerde değiştirilebilir.
Future<bool> Function(Uri uri) externalLinkLauncher = (uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
};

Future<void> Function(String text) clipboardWriter =
    (text) => Clipboard.setData(ClipboardData(text: text));

/// "Bağlantıyı Test Et" maili: konu ve gövde. Gövde, sunucunun bir fiş olarak okuyabileceği (mağaza + kalem + toplam) hazır metindir.
const kTestMailSubject = 'Fissio Test Fişi - Kahve Dünyası';
const kTestMailBody = 'Fissio e-posta aktarımı bağlantı testi.\n\nTarih: Bugün\nMağaza: Kahve Dünyası\n'
    '1 x Filtre Kahve: 85,00 TL\nToplam: 85,00 TL';

/// Kullanıcının Fissio adresine hazır test fişi yollayan `mailto:` (Türkçe karakterler ve satır sonları yüzde-kodlanır).
Uri testMailUri(String address) => Uri(
      scheme: 'mailto',
      path: address,
      query: 'subject=${Uri.encodeComponent(kTestMailSubject)}&body=${Uri.encodeComponent(kTestMailBody)}',
    );

Uri supportMailUri({String? version}) => Uri(
      scheme: 'mailto',
      path: supportEmail,
      query: 'subject=${Uri.encodeComponent('Fissio destek talebi')}'
          '&body=${Uri.encodeComponent('\n\n---\nUygulama sürümü: ${version ?? ''}')}',
    );
