// Başlatıcı ikonlarını (Android + iOS) logo çiziminden üretir; `lib/logo.dart` ile aynı kaynaktır.
// Çalıştırma (fissio_mobile/ içinde):  flutter test tool/generate_icons_test.dart
// `test/` altında olmadığı için normal `flutter test` çalıştırmasına girmez.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fissio_mobile/logo.dart';
import 'package:fissio_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<int>> _render(
  int px,
  Color color, {
  bool fill = true,
  bool rounded = true,
  double receiptScale = kLogoReceiptScale,
}) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  FissioLogoPainter(color: color, fill: fill, rounded: rounded, receiptScale: receiptScale)
      .paint(canvas, Size.square(px.toDouble()));
  final img = await rec.endRecording().toImage(px, px);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

void _write(String path, List<int> bytes) {
  final f = File(path)..createSync(recursive: true);
  f.writeAsBytesSync(bytes);
}

void _writeText(String path, String text) {
  final f = File(path)..createSync(recursive: true);
  f.writeAsStringSync(text);
}

void main() {
  testWidgets('başlatıcı ikonları üretilir', (tester) async {
    await tester.runAsync(() async {
      const res = 'android/app/src/main/res';
      // Android eski (API < 26) ikonlar: renkli yuvarlatılmış kare. dp: mdpi 48 ... xxxhdpi 192.
      const legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
      // Adaptive ön plan (108 dp tuval, güvenli bölge ~%61): yalnızca fiş, kare olmadan.
      const fg = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432};
      for (final p in kBrandPalette) {
        for (final e in legacy.entries) {
          _write('$res/mipmap-${e.key}/ic_launcher_${p.key}.png', await _render(e.value, p.color));
        }
        _writeText(
          '$res/mipmap-anydpi-v26/ic_launcher_${p.key}.xml',
          '<?xml version="1.0" encoding="utf-8"?>\n'
          '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <background android:drawable="@color/ic_bg_${p.key}"/>\n'
          '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
          '</adaptive-icon>\n',
        );
      }
      for (final e in fg.entries) {
        _write(
          '$res/mipmap-${e.key}/ic_launcher_foreground.png',
          await _render(e.value, Colors.transparent, fill: false, receiptScale: .6),
        );
      }
      // Varsayılan ikon = Kırmızı (marka rengi).
      final red = kBrandPalette.firstWhere((p) => p.key == 'red').color;
      for (final e in legacy.entries) {
        _write('$res/mipmap-${e.key}/ic_launcher.png', await _render(e.value, red));
      }
      _writeText(
        '$res/mipmap-anydpi-v26/ic_launcher.xml',
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_bg_red"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n',
      );
      _writeText(
        '$res/values/ic_launcher_colors.xml',
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '${[for (final p in kBrandPalette) '    <color name="ic_bg_${p.key}">${_hex(p.color)}</color>\n'].join()}'
        '</resources>\n',
      );

      // iOS: varsayılan AppIcon (kırmızı) tüm boyutlarda; diğer renkler 1024 px alternatif ikon kümeleri.
      const icons = 'ios/Runner/Assets.xcassets';
      final sizeRe = RegExp(r'Icon-App-([\d.]+)x[\d.]+@(\d)x\.png');
      for (final f in Directory('$icons/AppIcon.appiconset').listSync().whereType<File>()) {
        final m = sizeRe.firstMatch(f.uri.pathSegments.last);
        if (m == null) continue;
        final px = (double.parse(m[1]!) * int.parse(m[2]!)).round();
        f.writeAsBytesSync(await _render(px, red, rounded: false));
      }
      _write('$icons/AppIcon.appiconset/Icon-App-1024x1024@1x.png', await _render(1024, red, rounded: false));
      for (final p in kBrandPalette.where((p) => p.key != 'red')) {
        final dir = '$icons/AppIcon-${p.key}.appiconset';
        _write('$dir/Icon-1024.png', await _render(1024, p.color, rounded: false));
        _writeText(
          '$dir/Contents.json',
          '{\n  "images" : [\n    {\n      "filename" : "Icon-1024.png",\n      "idiom" : "universal",\n'
          '      "platform" : "ios",\n      "size" : "1024x1024"\n    }\n  ],\n'
          '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n',
        );
      }
      // Tasarım önizlemesi (ikon sayfası): 7 renk yan yana.
      final sheet = await _render(512, red);
      _write('build/logo_preview_red.png', sheet);
    });
  });
}
