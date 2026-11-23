import 'package:flutter/foundation.dart';

import 'theme_controller.dart' show PrefsStore, SecurePrefsStore;

/// Tanıtım (onboarding) akışının kalıcı durumu.
///
/// Tek bayrak tutulur: `onboarding_seen:<e-posta>` — o hesap kayıt sırasında akışı bir kez açtı;
/// otomatik gösterim bir daha olmaz (tamamlansa da atlansa da, uygulama yeniden başlasa da).
/// Ayarlar'daki "Uygulama Rehberi / Tanıtımı" satırı her zaman görünür; durum bayrağına bağlı değildir.
///
/// Giriş (login) ve oturum geri yükleme bu denetleyiciye hiç dokunmaz → onboarding açılmaz.
class OnboardingController extends ChangeNotifier {
  OnboardingController({PrefsStore? store}) : _store = store ?? const SecurePrefsStore();

  final PrefsStore _store;

  static const seenPrefix = 'onboarding_seen:';

  /// Eski sürümlerin yazdığı cihaz bayrağı artık okunmaz; yalnızca geriye dönük uyumluluk için adı durur.
  static const legacyReplayUsedKey = 'onboarding_replay_used';

  /// `runApp` öncesi çağrılır; yüklenecek kalıcı durum kalmadı (satır her zaman görünür), imza korunur.
  Future<void> load() async {}

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

  /// Son adım ("Başlayalım") ve "Atla": Ayarlar satırı etkilenmez, ek durum tutulmaz.
  Future<void> complete() async {}

  Future<void> skip() async {}

  Future<void> _save(String key, String value) async {
    try {
      await _store.write(key, value);
    } catch (_) {}
  }
}

final onboardingController = OnboardingController();
