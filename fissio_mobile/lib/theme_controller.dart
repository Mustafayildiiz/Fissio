import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'services/launcher_icon.dart';
import 'theme.dart';

/// Fiş okuma motoru tercihi: otomatik (bağlantı + senkron durumuna göre), sunucu OCR ya da cihaz içi OCR.
enum OcrMode { auto, server, onDevice }

/// Küçük anahtar-değer deposu (testlerde sahtesi verilebilir).
abstract class PrefsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Anahtar silebilen depo (oturum/hesap verisi için). Silemeyen depolarda AppState boş değer yazar.
abstract class DeletablePrefsStore implements PrefsStore {
  Future<void> delete(String key);
}

class SecurePrefsStore implements DeletablePrefsStore {
  const SecurePrefsStore();
  static const _s = FlutterSecureStorage();

  @override
  Future<void> delete(String key) => _s.delete(key: key);

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
}

/// Fiş detayının görünümü.
enum ReceiptStyle { paper, list }

/// Ana ekran widget'larının renk teması: sistem (açık/koyu'yu telefon belirler), sabit açık, sabit koyu ya da
/// marka rengi (logo/vurgu rengi arka plan olur). Yerel taraf `fissio_widget_theme` değerini adıyla okur.
enum WidgetTheme { system, light, dark, brand }

/// Özet (ana) ekranın özelleştirilebilir kartları. Toplam bloğu ve e-posta aktarım kartı (kendi yaşam döngüsü var)
/// listede değildir, her zaman yerinde kalır. Sıra = varsayılan sıra.
enum HomeCard {
  categories('Kategoriler'),
  budgets('Bütçeler'),
  fixed('Sabit giderler'),
  topReceipt('En yüksek fiş');

  const HomeCard(this.label);
  final String label;
}

/// Kayıtlı sırayı okur: bilinmeyen kimlikleri atar, tekrarları eler, eksik kartları varsayılan sırayla sona ekler.
List<HomeCard> parseHomeCardOrder(String? raw) {
  final out = <HomeCard>[];
  for (final part in (raw ?? '').split(',')) {
    final c = HomeCard.values.where((e) => e.name == part.trim()).firstOrNull;
    if (c != null && !out.contains(c)) out.add(c);
  }
  for (final c in HomeCard.values) {
    if (!out.contains(c)) out.add(c);
  }
  return out;
}

/// Gizli kart kümesi (bilinmeyen kimlikler atılır).
Set<HomeCard> parseHiddenHomeCards(String? raw) => {
  for (final part in (raw ?? '').split(','))
    ...HomeCard.values.where((e) => e.name == part.trim()),
};

/// Profile özel saklanabilen tema tercihleri: tema modu, vurgu rengi, logo rengi ve widget teması.
@immutable
class ThemePrefs {
  const ThemePrefs({required this.accent, required this.mode, this.logo, required this.widget});

  final Color accent;
  final ThemeMode mode;

  /// null = logo vurgu rengini izler.
  final Color? logo;
  final WidgetTheme widget;

  Map<String, Object?> toJson() => {
    'accent': accent.toARGB32(),
    'mode': mode.name,
    'logo': logo?.toARGB32(),
    'widget': widget.name,
  };

  /// Bozuk/eksik alan varsayılana düşer; kayıt hiç okunamazsa null.
  static ThemePrefs? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['accent'];
    if (a is! int) return null;
    final l = j['logo'];
    return ThemePrefs(
      accent: Color(a),
      mode: ThemeMode.values.firstWhere((e) => e.name == j['mode'], orElse: () => ThemeMode.system),
      logo: l is int ? Color(l) : null,
      widget: WidgetTheme.values.firstWhere((e) => e.name == j['widget'], orElse: () => WidgetTheme.system),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ThemePrefs &&
      other.accent.toARGB32() == accent.toARGB32() &&
      other.mode == mode &&
      other.logo?.toARGB32() == logo?.toARGB32() &&
      other.widget == widget;

  @override
  int get hashCode => Object.hash(accent.toARGB32(), mode, logo?.toARGB32(), widget);
}

/// Kayıtlı profil temaları JSON'unu okur (`{profileUid: ThemePrefs}`); bozuk değer/kayıt atlanır.
Map<String, ThemePrefs> parseProfileThemes(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final j = jsonDecode(raw);
    if (j is! Map) return {};
    return {
      for (final e in j.entries)
        if (e.key is String && ThemePrefs.fromJson(e.value) != null) e.key as String: ThemePrefs.fromJson(e.value)!,
    };
  } catch (_) {
    return {};
  }
}

/// Kullanıcının görünüm tercihleri: vurgu rengi, tema modu, fiş detay görünümü, uygulama logosu.
///
/// Tema (mod, vurgu, logo, widget teması) varsayılan olarak TÜM profillerde ortaktır. [perProfileTheme] açıkken bu dört
/// tercih aktif profil ([activeProfileUid]) için ayrı saklanır ([profileThemesKey] = tek JSON; `load()`'da okunur, böylece
/// profil geçişi senkron ve I/O'suzdur); profilin kaydı yoksa ortak değerler kullanılır. Anahtar kapatılınca ortak
/// tercihlere dönülür (profil kayıtları silinmez, yeniden açınca geri gelir). [accent]/[themeMode]/[logoOverride]/
/// [widgetTheme] her zaman ETKİN değerlerdir.
class ThemeController extends ChangeNotifier {
  ThemeController({PrefsStore? store, LauncherIcon? launcherIcon})
    : _store = store ?? const SecurePrefsStore(),
      _launcher = launcherIcon ?? const ChannelLauncherIcon();

  final PrefsStore _store;
  final LauncherIcon _launcher;

  static const accentKey = 'pref_accent';
  static const modeKey = 'pref_theme_mode';
  static const styleKey = 'pref_receipt_style';
  static const ocrModeKey = 'pref_ocr_mode';
  static const ocrEngineKey = 'pref_ocr_engine';
  static const logoKey = 'pref_logo';
  static const launcherKey = 'pref_launcher_icon';
  static const showOcrEngineKey = 'pref_show_ocr_engine';
  static const widgetThemeKey = 'pref_widget_theme';
  static const homeCardsKey = 'pref_home_cards';
  static const homeHiddenKey = 'pref_home_hidden';
  static const perProfileKey = 'pref_theme_per_profile';
  static const profileThemesKey = 'pref_profile_themes';

  /// "Profile özel tema kullan" (varsayılan kapalı = tüm profillerde ortak tema).
  bool perProfileTheme = false;

  /// Aktif profilin kimliği (`Profile.id`); AppState profil değişince bildirir. null = oturum yok / profil seçilmedi.
  String? activeProfileUid;

  /// Ortak (tüm profiller) tema tercihleri; profil teması kullanılırken de saklı kalır.
  ThemePrefs _shared = const ThemePrefs(accent: kDefaultAccent, mode: ThemeMode.system, widget: WidgetTheme.system);
  Map<String, ThemePrefs> _profileThemes = {};

  /// Yazımlar profil kaydına mı gider.
  bool get _scoped => perProfileTheme && activeProfileUid != null;

  ThemePrefs get _current => ThemePrefs(accent: accent, mode: themeMode, logo: logoOverride, widget: widgetTheme);

  void _apply(ThemePrefs p) {
    accent = p.accent;
    themeMode = p.mode;
    logoOverride = p.logo;
    widgetTheme = p.widget;
  }

  /// Etkin temayı (profil teması ya da ortak) uygular; değiştiyse dinleyicileri ve başlatıcı ikonunu günceller.
  bool _applyEffective() {
    final next = _scoped ? (_profileThemes[activeProfileUid] ?? _shared) : _shared;
    if (next == _current) return false;
    _apply(next);
    return true;
  }

  /// Aktif profil değişti (AppState çağırır). Profil teması kapalıysa yalnız kimlik saklanır.
  void setActiveProfile(String? uid) {
    if (uid == activeProfileUid) return;
    activeProfileUid = uid;
    if (!perProfileTheme) return;
    // Ana ekran ikonu ortak temayı izler: profil geçişi ikonu değiştirmez (Android'de activity-alias değişimi ana
    // ekrana sabitlenmiş kısayolu düşürebilir).
    if (_applyEffective()) notifyListeners();
  }

  /// "Profile özel tema kullan". Açılınca aktif profilin kaydı yoksa mevcut (ortak) temadan başlar; kapanınca ortak
  /// tercihlere dönülür.
  Future<void> setPerProfileTheme(bool on) async {
    if (on == perProfileTheme) return;
    perProfileTheme = on;
    final uid = activeProfileUid;
    final seed = on && uid != null && !_profileThemes.containsKey(uid);
    if (seed) _profileThemes = {..._profileThemes, uid: _shared};
    _applyEffective();
    notifyListeners();
    await _save(perProfileKey, on.toString());
    if (seed) await _saveProfileThemes();
  }

  /// [uid] profilinin kayıtlı teması (yoksa null).
  ThemePrefs? profileTheme(String uid) => _profileThemes[uid];

  Future<void> _saveProfileThemes() =>
      _save(profileThemesKey, jsonEncode({for (final e in _profileThemes.entries) e.key: e.value.toJson()}));

  /// Tema alanı değişti: profil teması kullanılıyorsa profilin kaydına, değilse ortak anahtara yazılır.
  Future<void> _persistTheme(String sharedKey, String value) async {
    if (_scoped) {
      _profileThemes = {..._profileThemes, activeProfileUid!: _current};
      await _saveProfileThemes();
    } else {
      _shared = _current;
      await _save(sharedKey, value);
    }
  }

  /// Sunucu OCR motoru (`OcrEngineFactory` anahtarı); tarama ekranı bunu kullanır.
  String ocrEngine = 'paddleocr';

  /// Fiş detayının altında "İşleyen Motor: …" satırı gösterilsin mi (varsayılan açık).
  bool showOcrEngine = true;

  /// Ana ekran widget'larının renk teması (tüm widget'lar aynı temayı kullanır).
  WidgetTheme widgetTheme = WidgetTheme.system;
  /// Özet ekranındaki kartların sırası ve gizli olanlar (yalnızca bu cihazda saklanır).
  List<HomeCard> homeCardOrder = List.of(HomeCard.values);
  Set<HomeCard> hiddenHomeCards = {};

  /// Sıralı ve gizlenmemiş kartlar.
  List<HomeCard> get visibleHomeCards => [for (final c in homeCardOrder) if (!hiddenHomeCards.contains(c)) c];

  Color accent = kDefaultAccent;
  ThemeMode themeMode = ThemeMode.system;
  ReceiptStyle receiptStyle = ReceiptStyle.paper;
  OcrMode ocrMode = OcrMode.auto;

  /// Sabit logo rengi; null = logo vurgu rengini (temayı) izler.
  Color? logoOverride;

  /// Uygulama içi logonun ve başlatıcı ikonunun arka plan rengi (tema izlenirken vurgu rengi).
  Color get logoColor => logoOverride ?? accent;
  bool get logoFollowsTheme => logoOverride == null;
  String? _appliedLauncher;
  Timer? _launcherTimer;

  /// `runApp` öncesi çağrılır; depolama okunamazsa varsayılanlarla devam eder.
  Future<void> load() async {
    try {
      // Her okuma bir platform kanalı + (Android'de) şifre çözme turudur; art arda beklemek ilk kareyi ~14 tur geciktirir.
      // Bağımsız oldukları için hepsi aynı anda istenir. Tek bir anahtarın okunamaması (ör. şifre çözme hatası) yalnız
      // o tercihi varsayılana düşürür; Future.wait'in ilk hatası diğer 10 tercihi de silmesin.
      Future<String?> read(String k) async {
        try {
          return await _store.read(k);
        } catch (_) {
          return null;
        }
      }

      final r = await Future.wait<String?>([
        read(accentKey),
        read(logoKey),
        read(launcherKey),
        read(modeKey),
        read(styleKey),
        read(ocrModeKey),
        read(ocrEngineKey),
        read(showOcrEngineKey),
        read(widgetThemeKey),
        read(homeCardsKey),
        read(homeHiddenKey),
        read(perProfileKey),
        read(profileThemesKey),
      ]);
      final a = r[0];
      final parsed = a == null ? null : int.tryParse(a);
      if (parsed != null) {
        accent = Color(parsed);
        // Eski varsayılan mor, tasarımdaki mora taşınır (swatch seçili görünsün).
        if (accent.toARGB32() == kLegacyPurple.toARGB32()) accent = kBrandPurple;
      }
      final lg = r[1];
      final lgParsed = lg == null ? null : int.tryParse(lg);
      logoOverride = lgParsed == null ? null : Color(lgParsed);
      _appliedLauncher = r[2];
      final m = r[3];
      themeMode = ThemeMode.values.firstWhere(
        (e) => e.name == m,
        orElse: () => ThemeMode.system,
      );
      final s = r[4];
      receiptStyle = ReceiptStyle.values.firstWhere(
        (e) => e.name == s,
        orElse: () => ReceiptStyle.paper,
      );
      final o = r[5];
      ocrMode = OcrMode.values.firstWhere((e) => e.name == o, orElse: () => OcrMode.auto);
      final e = r[6];
      if (e != null && e.isNotEmpty) ocrEngine = e;
      // Yalnızca açıkça 'false' yazılmışsa kapalı; yoksa/bozuksa varsayılan (açık).
      showOcrEngine = r[7] != 'false';
      final wt = r[8];
      widgetTheme = WidgetTheme.values.firstWhere((x) => x.name == wt, orElse: () => WidgetTheme.system);
      homeCardOrder = parseHomeCardOrder(r[9]);
      hiddenHomeCards = parseHiddenHomeCards(r[10]);
      perProfileTheme = r[11] == 'true';
      _profileThemes = parseProfileThemes(r[12]);
    } catch (_) {
      // Depolama yoksa (test/ilk açılış) varsayılanlar geçerli.
    }
    // Okunan tema alanları ortak tercihlerdir; profil seçiliyse (load'dan önce bildirildiyse) profil teması uygulanır.
    _shared = _current;
    _applyEffective();
    notifyListeners();
    unawaited(_syncLauncher(debounce: false));
  }

  Future<void> setAccent(Color c) async {
    accent = c;
    notifyListeners();
    await _persistTheme(accentKey, c.toARGB32().toString());
    unawaited(_syncLauncher());
  }

  /// Logo rengini ayarlar; null = temayı (vurgu rengini) izle. Başlatıcı ikonu da buna göre değişir.
  Future<void> setLogoColor(Color? c) async {
    logoOverride = c;
    notifyListeners();
    await _persistTheme(logoKey, c == null ? 'theme' : c.toARGB32().toString());
    unawaited(_syncLauncher());
  }

  /// Platform ana ekran ikonunu uygulama içinden değiştirebiliyor mu (Android'de yalnızca yayın sürümleri).
  Future<bool> get launcherSupported async {
    try {
      return await _launcher.supported;
    } catch (_) {
      return false;
    }
  }

  /// Ana ekran (başlatıcı) ikonunun rengi: HER ZAMAN ortak temanın logosu (profil teması açıkken de). Uygulama içi logo
  /// ise etkin (profil) temayı izler ([logoColor]).
  Color get launcherColor => _shared.logo ?? _shared.accent;

  /// Başlatıcı (launcher) ikonunu [launcherColor]'a eşitler. Platform desteklemiyorsa (test/masaüstü) hiçbir şey
  /// yapmaz. Swatch'lara art arda dokunulurken ikon sürekli değişmesin diye kısa gecikmeyle birleştirilir.
  Future<void> _syncLauncher({bool debounce = true}) async {
    try {
      if (!await _launcher.supported) return;
      final key = brandKeyOf(launcherColor);
      // Bekleyen (başka renge ait) değişiklik HER durumda iptal edilir: A'ya dokunup 1,5 sn içinde uygulanmış renge
      // geri dönülürse erken dönüş A'nın zamanlayıcısını çalışır bırakır, ikon logoyla uyuşmazdı.
      _launcherTimer?.cancel();
      _launcherTimer = null;
      if (key == _appliedLauncher) return;
      Future<void> apply() async {
        try {
          if (await _launcher.set(key)) {
            _appliedLauncher = key;
            await _save(launcherKey, key);
          }
        } catch (_) {
          // Zamanlayıcıdan çalışır: hata yakalanmazsa işlenmemiş async hata olurdu.
        }
      }

      if (!debounce) return await apply();
      _launcherTimer = Timer(const Duration(milliseconds: 1500), apply);
    } catch (_) {}
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return; // load()/setX await sonrası dispose edilmiş olabilir (testler)
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _launcherTimer?.cancel();
    super.dispose();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    notifyListeners();
    await _persistTheme(modeKey, m.name);
  }

  Future<void> setReceiptStyle(ReceiptStyle s) async {
    receiptStyle = s;
    notifyListeners();
    await _save(styleKey, s.name);
  }

  Future<void> setOcrMode(OcrMode m) async {
    ocrMode = m;
    notifyListeners();
    await _save(ocrModeKey, m.name);
  }

  Future<void> setOcrEngine(String e) async {
    ocrEngine = e;
    notifyListeners();
    await _save(ocrEngineKey, e);
  }

  Future<void> setShowOcrEngine(bool v) async {
    showOcrEngine = v;
    notifyListeners();
    await _save(showOcrEngineKey, v.toString());
  }

  Future<void> setWidgetTheme(WidgetTheme t) async {
    widgetTheme = t;
    notifyListeners();
    await _persistTheme(widgetThemeKey, t.name);
  }

  Future<void> setHomeCardOrder(List<HomeCard> order) async {
    homeCardOrder = parseHomeCardOrder(order.map((c) => c.name).join(','));
    notifyListeners();
    await _save(homeCardsKey, homeCardOrder.map((c) => c.name).join(','));
  }

  Future<void> setHomeCardHidden(HomeCard card, bool hidden) async {
    hiddenHomeCards = {...hiddenHomeCards}..remove(card);
    if (hidden) hiddenHomeCards.add(card);
    notifyListeners();
    await _save(homeHiddenKey, hiddenHomeCards.map((c) => c.name).join(','));
  }

  /// Sıra ve gizlemeyi varsayılana döndürür.
  Future<void> resetHomeCards() async {
    homeCardOrder = List.of(HomeCard.values);
    hiddenHomeCards = {};
    notifyListeners();
    await _save(homeCardsKey, '');
    await _save(homeHiddenKey, '');
  }

  Future<void> _save(String key, String value) async {
    try {
      await _store.write(key, value);
    } catch (_) {}
  }
}

final themeController = ThemeController();
