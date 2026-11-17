import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Destek e-posta adresi (Destek ekranı ve Gizlilik Politikası'ndaki iletişim bilgisi).
const supportEmail = 'mustafa935yildiz@gmail.com';

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

Future<void> Function(String text) clipboardWriter =
    (text) => Clipboard.setData(ClipboardData(text: text));

Uri supportMailUri({String? version}) => Uri(
      scheme: 'mailto',
      path: supportEmail,
      query: 'subject=${Uri.encodeComponent('Fissio destek talebi')}'
          '&body=${Uri.encodeComponent('\n\n---\nUygulama sürümü: ${version ?? ''}')}',
    );
