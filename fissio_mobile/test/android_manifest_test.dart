import 'dart:io';

import 'package:fissio_mobile/services/widget_sync.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// Android başlatıcı girişleri (MainActivity + renk takma adları) ve widget'lar için manifest/kaynak eşitliği.
///
/// Seçili renk dışındaki girişler devre dışıdır: paylaşım hedefi ("Paylaş → Fissio") ve derin bağlantılar YALNIZCA
/// etkin girişte çalışır. Bu yüzden HER girişte aynı filtreler olmalıdır; bir renk eksik kalırsa o renk seçildiğinde
/// widget kısayolu ya da PDF paylaşımı sessizce kaybolur.
void main() {
  final root = Directory('android/app/src/main');
  final manifest = File('${root.path}/AndroidManifest.xml').readAsStringSync();

  /// Giriş adı → o girişin gövde metni (`<activity ...>...</activity>` / `<activity-alias ...>...</activity-alias>`).
  final entries = <String, String>{
    for (final m in RegExp(r'<(activity|activity-alias)\s[^>]*?android:name="\.([A-Za-z]+)"[\s\S]*?</\1>').allMatches(manifest))
      m[2]!: m[0]!,
  };

  /// Bir girişin intent-filter'larının normalize edilmiş özeti (sıradan bağımsız).
  Set<String> filtersOf(String body) => {
    for (final f in RegExp(r'<intent-filter>([\s\S]*?)</intent-filter>').allMatches(body))
      (RegExp(r'android:(?:name|scheme|host|mimeType)="([^"]+)"').allMatches(f[1]!).map((m) => m[1]!).toList()..sort()).join('|'),
  };

  test('7 başlatıcı girişi var: MainActivity + 6 takma ad (Kotlin ALIASES ile aynı)', () {
    final kt = File('${root.path}/kotlin/com/example/fissio_mobile/MainActivity.kt').readAsStringSync();
    final aliases = {
      for (final m in RegExp(r'"(\w+)"\s+to\s+"(\w+)"').allMatches(kt.substring(kt.indexOf('val ALIASES')))) m[1]!: m[2]!,
    };
    expect(aliases.keys.toSet(), kBrandPalette.map((o) => o.key).toSet(), reason: 'Dart paletiyle aynı anahtarlar');
    for (final name in aliases.values) {
      expect(entries.containsKey(name), isTrue, reason: '$name manifestte tanımlı olmalı');
    }
    expect(aliases.length, 7);
  });

  test('her renk girişi AYNI filtreleri taşır: scan, import-digital, PDF SEND/VIEW (+ deeplinking kapalı)', () {
    final names = {'MainActivity', 'LauncherPurple', 'LauncherGreen', 'LauncherDarkred', 'LauncherBlue', 'LauncherGraphite', 'LauncherInk'};
    expect(entries.keys.toSet().containsAll(names), isTrue);
    final reference = filtersOf(entries['MainActivity']!);
    // Beklenen 4 filtre (+ LAUNCHER): kamera, dijital fiş, PDF paylaşımı, PDF "birlikte aç".
    expect(reference.any((f) => f.contains('scan') && f.contains('fissio')), isTrue, reason: 'fissio://scan');
    expect(reference.any((f) => f.contains('import-digital') && f.contains('fissio')), isTrue, reason: 'fissio://import-digital');
    expect(reference.any((f) => f.contains('android.intent.action.SEND') && f.contains('application/pdf')), isTrue, reason: 'PDF paylaşımı');
    expect(reference.any((f) => f.contains('android.intent.action.VIEW') && f.contains('application/pdf')), isTrue, reason: 'PDF aç');
    // Dijital fiş paylaşımı: .eml (message/rfc822) ve HTML sipariş özeti de PDF ile aynı SEND/VIEW filtrelerinde.
    for (final type in ['message/rfc822', 'text/html']) {
      expect(reference.any((f) => f.contains('android.intent.action.SEND') && f.contains(type)), isTrue, reason: '$type paylaşımı');
      expect(reference.any((f) => f.contains('android.intent.action.VIEW') && f.contains(type)), isTrue, reason: '$type aç');
    }
    for (final n in names) {
      expect(filtersOf(entries[n]!), reference, reason: '$n girişinin filtreleri MainActivity ile aynı olmalı');
      expect(entries[n]!.contains('flutter_deeplinking_enabled'), isTrue, reason: '$n: Flutter varsayılan derin bağlantısı kapalı olmalı');
      expect(RegExp(r'flutter_deeplinking_enabled"\s+android:value="false"').hasMatch(entries[n]!), isTrue, reason: n);
    }
  });

  test('4 widget: alıcı + bilgi XML + düzen + sağlayıcı sınıfı var; Dart anahtarlarıyla aynı', () {
    final dartProviders = WidgetKeys.providers.map((p) => p.android).toList();
    expect(dartProviders, ['FissioWidgetProvider', 'FissioScanWidgetProvider', 'FissioDigitalWidgetProvider', 'FissioCombinedWidgetProvider']);
    for (final cls in dartProviders) {
      expect(manifest.contains('android:name=".$cls"'), isTrue, reason: '$cls manifestte <receiver>');
      expect(File('${root.path}/kotlin/com/example/fissio_mobile/$cls.kt').existsSync(), isTrue, reason: '$cls.kt');
    }
    for (final xml in ['fissio_widget_info', 'fissio_scan_widget_info', 'fissio_digital_widget_info', 'fissio_combined_widget_info']) {
      expect(manifest.contains('@xml/$xml'), isTrue, reason: xml);
      final f = File('${root.path}/res/xml/$xml.xml');
      expect(f.existsSync(), isTrue, reason: xml);
      final layout = RegExp(r'android:initialLayout="@layout/(\w+)"').firstMatch(f.readAsStringSync())![1]!;
      expect(File('${root.path}/res/layout/$layout.xml').existsSync(), isTrue, reason: '$xml → $layout');
    }
  });

  test('widget düzenleri yalnızca RemoteViews\'in şişirebildiği sınıfları kullanır (Space/View yasak)', () {
    for (final f in Directory('${root.path}/res/layout').listSync().whereType<File>()) {
      final text = f.readAsStringSync();
      expect(RegExp(r'<(Space|View)[\s/>]').hasMatch(text), isFalse, reason: '${f.path}: <Space>/<View> RemoteViews\'te çöker');
    }
  });

  test('her widget iki yönlü tıklanır: dijital fiş düğmesi fissio://import-digital, tarama düğmesi fissio://scan', () {
    final kt = Directory('${root.path}/kotlin/com/example/fissio_mobile');
    String read(String n) => File('${kt.path}/$n').readAsStringSync();
    expect(read('FissioScanWidgetProvider.kt'), contains('SCAN_URI'));
    expect(read('FissioDigitalWidgetProvider.kt'), contains('IMPORT_URI'));
    final combined = read('FissioCombinedWidgetProvider.kt');
    expect(combined, allOf(contains('SCAN_URI'), contains('IMPORT_URI')));
    final main = read('FissioWidgetProvider.kt');
    expect(main, allOf(contains('SCAN_URI'), contains('IMPORT_URI')));
    final theming = read('WidgetTheming.kt');
    expect(theming, contains('fissio://scan'));
    expect(theming, contains('fissio://import-digital'));
    // Tema anahtarları Dart ile aynı.
    expect(theming, contains(WidgetKeys.theme));
    expect(theming, contains(WidgetKeys.accent));
  });

  test('MainActivity SHARED_TYPES = manifestteki paylaşım MIME türleri (pdf/eml/html uzantı eşlemesiyle)', () {
    final kt = File('${root.path}/kotlin/com/example/fissio_mobile/MainActivity.kt').readAsStringSync();
    final block = kt.substring(kt.indexOf('val SHARED_TYPES'), kt.indexOf('const val CHANNEL'));
    final map = {for (final m in RegExp(r'"([a-z]+/[a-z0-9.+-]+)"\s+to\s+"(\w+)"').allMatches(block)) m[1]!: m[2]!};
    expect(map, {'application/pdf': 'pdf', 'message/rfc822': 'eml', 'text/html': 'html'});
    final reference = filtersOf(entries['MainActivity']!);
    final manifestTypes = {
      for (final f in reference)
        for (final part in f.split('|'))
          if (RegExp(r'^[a-z]+/[a-z0-9.+-]+$').hasMatch(part) && !part.startsWith('android.')) part,
    };
    expect(manifestTypes, map.keys.toSet());
    // Soğuk/sıcak açılışta yalnızca uzantıya göre dağıtılır: Dart tarafı .pdf/.eml/.html'i tanır.
    expect(kt.contains('EXTRA_HTML_TEXT'), isTrue, reason: 'EXTRA_STREAM olmadan HTML paylaşımı');
  });
}
