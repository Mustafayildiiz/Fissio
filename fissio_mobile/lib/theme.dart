import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

// ─── Tasarım sabitleri (Fissio iOS / Modernist) ───────────────────────────

const fontFamily = 'Archivo';

/// Fissio marka rengi (tasarım sisteminin `--color-accent` değeri). Varsayılan vurgu; Tercihler'den değiştirilebilir.
const kDefaultAccent = Color(0xFFEC3013);

/// Eski varsayılan mor (#7C4DFF). Kayıtlı tercihte kalmış olabilir; tasarımdaki mora ([kBrandPurple]) taşınır.
const kLegacyPurple = Color(0xFF7C4DFF);
const kBrandPurple = Color(0xFF5B3FD1);

/// "Fissio Logo Final" tasarımının renk paleti: hem vurgu renkleri hem de uygulama logosu / başlatıcı ikonu
/// arka planı. [key] başlatıcı ikon takma adlarıyla (Android activity-alias, iOS alternatif ikon) eşleşir.
/// Sıra: ilk dört eski seçenekle aynıdır (kayıtlı tercihler ve testler bozulmasın).
const kBrandPalette = <({String key, String name, Color color})>[
  (key: 'purple', name: 'Mor', color: kBrandPurple),
  (key: 'green', name: 'Yeşil', color: Color(0xFF1F8A4C)),
  (key: 'darkred', name: 'Koyu kırmızı', color: Color(0xFFAE1800)),
  (key: 'red', name: 'Kırmızı', color: Color(0xFFEC3013)),
  (key: 'blue', name: 'Mavi', color: Color(0xFF1F5FD1)),
  (key: 'graphite', name: 'Grafit', color: Color(0xFF3A3736)),
  (key: 'ink', name: 'Mürekkep', color: Color(0xFF201E1D)),
];

/// Tercihler ekranında sunulan vurgu renkleri (marka paletinin aynısı).
const kAccentOptions = <({String name, Color color})>[
  (name: 'Mor', color: kBrandPurple),
  (name: 'Yeşil', color: Color(0xFF1F8A4C)),
  (name: 'Koyu kırmızı', color: Color(0xFFAE1800)),
  (name: 'Kırmızı', color: Color(0xFFEC3013)),
  (name: 'Mavi', color: Color(0xFF1F5FD1)),
  (name: 'Grafit', color: Color(0xFF3A3736)),
  (name: 'Mürekkep', color: Color(0xFF201E1D)),
];

/// [color]'a en yakın marka paleti anahtarı (paletteki bir renkse birebir; değilse kırmızı).
String brandKeyOf(Color color) {
  for (final p in kBrandPalette) {
    if (p.color.toARGB32() == color.toARGB32()) return p.key;
  }
  return 'red';
}

/// Koyu zeminde neredeyse siyah vurgular (Mürekkep, Grafit) dolgu olarak görünmez olur; bu eşiğin altındakiler
/// koyu temada açık bir dolguya çevrilir.
const double _kDarkAccentLuminance = .08;

/// Neredeyse siyah renk (Mürekkep/Grafit): koyu zeminde göze batmaz, ayrıca açılaştırılır.
bool isNearBlack(Color c) => c.computeLuminance() < _kDarkAccentLuminance;

/// Uygulama içi logo karesinin koyu temada gösterilen rengi: neredeyse siyah marka renkleri koyu zeminde kaybolur,
/// bu yüzden hafifçe açılır (fişin beyaz çizimi bozulmaz). Diğer renkler ve açık tema aynen.
Color logoTileColorFor(Color c, Brightness brightness) =>
    brightness == Brightness.dark && isNearBlack(c) ? Color.lerp(c, Colors.white, .22)! : c;

/// Silme / hata için sabit kırmızı (vurgu rengine bağlı değildir).
const kDanger = Color(0xFFD92D20);
const kDangerDark = Color(0xFFFF6B5E);

const double kRadius = 14; // kart
const double kRadiusSm = 10; // küçük kutu, segmented, ikon karesi
const double kRadiusPill = 999;

/// Tasarım tokenları; açık/koyu temaya göre `ThemeData.extensions` içinde taşınır.
@immutable
class FissioColors extends ThemeExtension<FissioColors> {
  const FissioColors({
    required this.bg,
    required this.surf,
    required this.surf2,
    required this.ink,
    required this.mute,
    required this.line,
    required this.rule,
    required this.bar,
    required this.paper,
    required this.seg4,
    required this.accent,
    required this.accentInk,
    required this.onAccent,
    required this.danger,
    required this.warn,
    required this.isDark,
  });

  final Color bg;
  final Color surf;
  final Color surf2;
  final Color ink;
  final Color mute;
  final Color line;
  final Color rule;
  final Color bar;
  final Color paper;
  final Color seg4;
  final Color accent;

  /// Metin/ikon olarak kullanılan vurgu (koyu zeminde okunaklı olacak şekilde açılır).
  final Color accentInk;

  /// Vurgu dolgusu üzerindeki metin/ikon rengi (dolgunun parlaklığına göre).
  final Color onAccent;
  final Color danger;

  /// Uyarı (sarı): bütçe %80 eşiği.
  final Color warn;
  final bool isDark;

  factory FissioColors.light([Color accent = kDefaultAccent]) => FissioColors(
        bg: const Color(0xFFF3F2F2),
        surf: const Color(0xFFFFFFFF),
        surf2: const Color(0xFFEAE9E9),
        ink: const Color(0xFF201E1D),
        mute: const Color(0xFF605D5D),
        line: const Color(0x1F201E1D),
        rule: const Color(0xFF201E1D),
        bar: const Color(0xF0F3F2F2),
        paper: const Color(0xFFFFFFFF),
        seg4: const Color(0xFFBAB6B6),
        accent: accent,
        accentInk: accent,
        onAccent: Colors.white,
        danger: kDanger,
        warn: const Color(0xFFE5A100),
        isDark: false,
      );

  factory FissioColors.dark([Color accent = kDefaultAccent]) {
    final hsl = HSLColor.fromColor(accent);
    final ink = hsl.lightness < .6 ? hsl.withLightness(.64).toColor() : accent;
    // Neredeyse siyah vurgu (Mürekkep/Grafit): koyu zeminde dolgu da açık olur, üstündeki metin koyu kalır.
    final nearBlack = accent.computeLuminance() < _kDarkAccentLuminance;
    final fill = nearBlack ? const Color(0xFFE9E7E6) : accent;
    return FissioColors(
      bg: const Color(0xFF121110),
      surf: const Color(0xFF1F1D1C),
      surf2: const Color(0xFF2F2D2C),
      ink: const Color(0xFFF3F2F2),
      mute: const Color(0xFF9B9797),
      line: const Color(0x1FF3F2F2),
      rule: const Color(0xFFF3F2F2),
      bar: const Color(0xF0121110),
      paper: const Color(0xFF262423),
      seg4: const Color(0xFF605D5D),
      accent: fill,
      accentInk: nearBlack ? fill : ink,
      onAccent: nearBlack ? const Color(0xFF201E1D) : Colors.white,
      danger: kDangerDark,
      warn: const Color(0xFFFFC53D),
      isDark: true,
    );
  }

  @override
  FissioColors copyWith({Color? accent}) => isDark
      ? FissioColors.dark(accent ?? this.accent)
      : FissioColors.light(accent ?? this.accent);

  @override
  FissioColors lerp(ThemeExtension<FissioColors>? other, double t) {
    if (other is! FissioColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return FissioColors(
      bg: l(bg, other.bg),
      surf: l(surf, other.surf),
      surf2: l(surf2, other.surf2),
      ink: l(ink, other.ink),
      mute: l(mute, other.mute),
      line: l(line, other.line),
      rule: l(rule, other.rule),
      bar: l(bar, other.bar),
      paper: l(paper, other.paper),
      seg4: l(seg4, other.seg4),
      accent: l(accent, other.accent),
      accentInk: l(accentInk, other.accentInk),
      onAccent: l(onAccent, other.onAccent),
      danger: l(danger, other.danger),
      warn: l(warn, other.warn),
      isDark: t < .5 ? isDark : other.isDark,
    );
  }
}

extension FissioColorsContext on BuildContext {
  /// Tema yoksa (çıplak MaterialApp, testler) açık/koyu varsayılana düşer.
  FissioColors get c {
    final theme = Theme.of(this);
    return theme.extension<FissioColors>() ??
        (theme.brightness == Brightness.dark
            ? FissioColors.dark()
            : FissioColors.light());
  }
}

/// Başlık / etiket / satır metin stilleri (tasarımdaki ölçüler).
class FissioText {
  static const _tnum = [FontFeature.tabularFigures()];

  static TextStyle title(FissioColors c, {double size = 34}) => TextStyle(
        fontFamily: fontFamily,
        fontWeight: FontWeight.w800,
        fontSize: size,
        height: 1.1,
        letterSpacing: -size * .02,
        color: c.ink,
      );

  static TextStyle label(FissioColors c) => TextStyle(
        fontFamily: fontFamily,
        fontWeight: FontWeight.w600,
        fontSize: 13,
        height: 1,
        letterSpacing: 1.04,
        color: c.mute,
      );

  static TextStyle body(FissioColors c,
          {double size = 16, FontWeight weight = FontWeight.w400, Color? color}) =>
      TextStyle(
        fontFamily: fontFamily,
        fontWeight: weight,
        fontSize: size,
        height: 1.25,
        color: color ?? c.ink,
      );

  /// Tutarlar için sabit genişlikli rakamlar.
  static TextStyle money(FissioColors c,
          {double size = 16,
          FontWeight weight = FontWeight.w600,
          Color? color,
          double letterSpacing = 0}) =>
      TextStyle(
        fontFamily: fontFamily,
        fontWeight: weight,
        fontSize: size,
        height: 1.1,
        letterSpacing: letterSpacing,
        color: color ?? c.ink,
        fontFeatures: _tnum,
      );
}

ThemeData buildTheme({
  Brightness brightness = Brightness.light,
  Color accent = kDefaultAccent,
}) {
  final c = brightness == Brightness.dark
      ? FissioColors.dark(accent)
      : FissioColors.light(accent);
  // Yalnızca primary ailesi vurgudan türer; yüzeyler nötr kalır ("ink on ground").
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
  ).copyWith(
    primary: c.accentInk,
    onPrimary: c.onAccent,
    secondary: c.accentInk,
    surface: c.bg,
    onSurface: c.ink,
    onSurfaceVariant: c.mute,
    surfaceTint: Colors.transparent,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.surf,
    surfaceContainer: c.surf,
    surfaceContainerHigh: c.surf,
    surfaceContainerHighest: c.surf2,
    outline: c.mute,
    outlineVariant: c.line,
    error: c.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: fontFamily,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.surf,
    splashFactory: InkRipple.splashFactory,
    extensions: [c],
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
    iconTheme: IconThemeData(color: c.ink),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surf,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
      titleTextStyle: FissioText.title(c, size: 20),
      contentTextStyle: FissioText.body(c, size: 15, color: c.mute),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surf,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.surf,
      showDragHandle: true,
      dragHandleColor: c.line,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadius + 6)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: TextStyle(color: c.mute),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      isDense: true,
      contentPadding: EdgeInsets.zero,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accentInk,
      selectionColor: c.accent.withValues(alpha: .3),
      selectionHandleColor: c.accentInk,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accentInk),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accentInk,
        textStyle: const TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surf,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadiusSm)),
    ),
  );
}

// ─── Biçimleyiciler (testler bunlara bağlı: değiştirmeyin) ────────────────

String fmtMoney(double v) {
  final fixed = v.toStringAsFixed(2);
  final parts = fixed.split('.');
  final intPart = parts[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => '.',
  );
  return '$intPart,${parts[1]} ₺';
}

String fmtDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Tarih seçicilerin `lastDate` değeri: cihazın YEREL gününün başlangıcı (gelecek tarih seçilemez; yarının fişi
/// özet dönemlerinden düşüp bütçe/widget ay toplamında kalıyordu).
DateTime pickableToday([DateTime? now]) {
  final n = now ?? DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// `showDatePicker`, `initialDate > lastDate` ise assert eder (OCR tarihi now+2 güne kadar izin verir): içeri çeker.
DateTime clampPickerDate(DateTime d, DateTime last) {
  final day = DateTime(d.year, d.month, d.day);
  return day.isAfter(last) ? last : day;
}

const kMonthNames = [
  'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
  'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık',
];
