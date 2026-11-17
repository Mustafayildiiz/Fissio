import 'package:flutter/foundation.dart';

import 'theme_controller.dart' show PrefsStore, SecurePrefsStore;

/// Tanıtım (onboarding) akışının kalıcı durumu.
///
/// İki bağımsız bayrak tutulur:
/// - `onboarding_seen:<e-posta>`: o hesap kayıt sırasında akışı bir kez açtı; otomatik gösterim
///   bir daha olmaz (tamamlansa da atlansa da, uygulama yeniden başlasa da).
/// - `onboarding_replay_used` (cihaz bazlı): Ayarlar'daki "Tanıtım Rehberini Görüntüle" satırı
///   kullanıldı/tamamlandı. Cihaz bazlıdır çünkü profil değiştirince oturum e-postası
///   (`p_…@fissio.local`) değişir; e-postaya bağlansaydı aynı kişiye satır her profilde yeniden çıkardı.
///
/// Giriş (login) ve oturum geri yükleme bu denetleyiciye hiç dokunmaz → onboarding açılmaz.
class OnboardingController extends ChangeNotifier {
  OnboardingController({PrefsStore? store}) : _store = store ?? const SecurePrefsStore();

  final PrefsStore _store;

  static const seenPrefix = 'onboarding_seen:';
  static const replayUsedKey = 'onboarding_replay_used';

  bool _replayUsed = false;

  /// Ayarlar satırı görünür mü? Rehberi tamamlamamış / hiç görmemiş / atlamış kullanıcıda true.
  bool get replayAvailable => !_replayUsed;

  /// `runApp` öncesi çağrılır; depolama okunamazsa varsayılanlarla devam eder.
  Future<void> load() async {
    try {
      _replayUsed = await _store.read(replayUsedKey) == '1';
    } catch (_) {
      // Depolama yoksa (test/ilk açılış) varsayılanlar geçerli.
    }
    notifyListeners();
  }

  /// Yeni kayıttan sonra akış otomatik gösterilmeli mi? (Girişte bu hiç çağrılmaz.)
  Future<bool> shouldShowAfterSignUp(String? email) async {
    try {
      return await _store.read('$seenPrefix${email ?? ''}') != '1';
    } catch (_) {
      return true;
    }
  }

  /// Kayıt akışı ekrana gelir gelmez işaretlenir: uygulama ortasında kapansa da tekrar açılmaz.
  Future<void> markShownAtSignUp(String? email) =>
      _save('$seenPrefix${email ?? ''}', '1');

  /// Son adım ("Başlayalım"): Ayarlar satırı kalıcı olarak gizlenir.
  Future<void> complete() => _setReplayUsed();

  /// "Atla": rehber görülmemiş sayılır, Ayarlar satırı açık kalır (bayrak değişmez).
  Future<void> skip() async {}

  /// Ayarlar satırına dokunuldu: akış bir kez gösterilir ve satır kalıcı olarak kaldırılır.
  Future<void> markReplayOpened() => _setReplayUsed();

  Future<void> _setReplayUsed() async {
    _replayUsed = true;
    notifyListeners();
    await _save(replayUsedKey, '1');
  }

  Future<void> _save(String key, String value) async {
    try {
      await _store.write(key, value);
    } catch (_) {}
  }
}

final onboardingController = OnboardingController();
