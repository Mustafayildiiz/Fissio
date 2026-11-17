import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'models.dart';
import 'ocr/ocr_engine.dart';

class AppState extends ChangeNotifier {
  AppState() {
    api = ApiClient(onUnauthorized: _handleUnauthorized);
  }

  late final ApiClient api;
  final OcrEngineFactory ocrFactory = OcrEngineFactory(
    defaultEngine: 'paddleocr',
  );
  final _storage = const FlutterSecureStorage();
  static const _tokenKey = 'jwt';
  static const _profilesKey = 'profiles_v2';
  static const _activeProfileKey = 'active_profile_v2';

  String? email;
  String? profileName;
  String? activeProfileId;
  List<UserProfile> profiles = [];
  List<Expense> expenses = [];
  List<Category> categories = [];
  bool loading = false;
  String? error;

  VoidCallback? onSessionExpired;

  bool get loggedIn => api.token != null;

  String get displayName => profileName ?? email ?? 'Profil';

  /// Kayıtlı profilleri yükler; hiç profil yoksa yalnızca 1 varsayılan profil oluşturur.
  Future<void> loadProfiles() async {
    try {
      final raw = await _storage.read(key: _profilesKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        profiles = list.map((e) => UserProfile.fromJson(e)).toList();
      }
    } catch (_) {
      profiles = [];
    }
    if (profiles.isEmpty) {
      profiles = [_makeLocalProfile('Profil 1', 1)];
      await _saveProfiles();
    }
    activeProfileId = await _storage.read(key: _activeProfileKey);
    notifyListeners();
  }

  UserProfile _makeLocalProfile(String name, int seed) {
    final rnd = Random().nextInt(900000) + 100000;
    final id = '${DateTime.now().millisecondsSinceEpoch}_${seed}_$rnd';
    return UserProfile(
      id: id,
      name: name,
      email: 'p_$id@fissio.local',
      password: 'fissio_${id}_pw',
    );
  }

  Future<void> _saveProfiles() => _storage.write(
    key: _profilesKey,
    value: jsonEncode(profiles.map((p) => p.toJson()).toList()),
  );

  /// Yeni profil ekler (Ev, İş vb.) ve seçer.
  Future<void> createProfile(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final p = _makeLocalProfile(trimmed, profiles.length + 1);
    profiles.add(p);
    await _saveProfiles();
    await selectProfile(p);
  }

  /// Profil siler (en az 1 profil kalmalıdır).
  Future<void> deleteProfile(String id) async {
    if (profiles.length <= 1) return;
    profiles.removeWhere((p) => p.id == id);
    await _saveProfiles();
    if (activeProfileId == id) {
      await selectProfile(profiles.first);
    } else {
      notifyListeners();
    }
  }

  /// Profil adını günceller.
  Future<void> renameProfile(String id, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final idx = profiles.indexWhere((p) => p.id == id);
    if (idx >= 0) {
      profiles[idx] = profiles[idx].copyWith(name: trimmed);
      if (activeProfileId == id) {
        profileName = trimmed;
      }
      await _saveProfiles();
      notifyListeners();
    }
  }

  /// Seçilen profilin oturumunu arka planda açar ve verilerini yükler.
  Future<void> selectProfile(UserProfile p) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      String? tok = p.token;
      if (tok != null) {
        api.token = tok;
        try {
          await api.me();
        } catch (_) {
          tok = null;
        }
      }
      if (tok == null) {
        try {
          await api.register(p.email, p.password);
        } on ApiException catch (e) {
          if (e.status != 409) rethrow;
        }
        final r = await api.login(p.email, p.password);
        tok = r.token;
      }
      api.token = tok;
      email = p.email;
      profileName = p.name;
      activeProfileId = p.id;
      final idx = profiles.indexWhere((x) => x.id == p.id);
      if (idx >= 0) {
        profiles[idx] = p.copyWith(token: tok);
        await _saveProfiles();
      }
      await _storage.write(key: _activeProfileKey, value: p.id);
      await _storage.write(key: _tokenKey, value: tok);
      await refresh();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Kayıtlı token'ı ve profilleri yükler.
  Future<bool> restoreSession() async {
    await loadProfiles();
    try {
      final t = await _storage.read(key: _tokenKey);
      if (t == null) return false;
      api.token = t;
      final meMail = await api.me();
      email = meMail;
      final match = profiles.where((p) => p.email == meMail).firstOrNull;
      profileName = match?.name ?? meMail.split('@').first;
      activeProfileId = match?.id;
      return true;
    } on ApiException catch (e) {
      if (!e.network) await _clear();
      api.token = null;
      return false;
    } catch (_) {
      api.token = null;
      return false;
    }
  }

  Future<void> login(String mail, String password) async {
    if (profiles.isEmpty) {
      await loadProfiles();
    }
    final r = await api.login(mail, password);
    api.token = r.token;
    email = r.email;
    final existing = profiles.indexWhere((p) => p.email == r.email);
    if (existing >= 0) {
      profiles[existing] = profiles[existing].copyWith(token: r.token);
      activeProfileId = profiles[existing].id;
      profileName = profiles[existing].name;
    } else if (profiles.length == 1 && profiles.first.name == 'Profil 1') {
      profiles[0] = profiles[0].copyWith(
        email: r.email,
        password: password,
        token: r.token,
      );
      activeProfileId = profiles[0].id;
      profileName = profiles[0].name;
    } else {
      final p = UserProfile(
        id: 'acc_${DateTime.now().millisecondsSinceEpoch}',
        name: 'Profil ${profiles.length + 1}',
        email: r.email,
        password: password,
        token: r.token,
      );
      profiles.add(p);
      activeProfileId = p.id;
      profileName = p.name;
    }
    await _saveProfiles();
    await _storage.write(key: _tokenKey, value: r.token);
    if (activeProfileId != null) {
      await _storage.write(key: _activeProfileKey, value: activeProfileId!);
    }
    notifyListeners();
  }

  Future<void> register(String mail, String password) async {
    await api.register(mail, password);
    await login(mail, password);
  }

  Future<void> logout() async {
    await _clear();
    api.token = null;
    email = null;
    profileName = null;
    activeProfileId = null;
    expenses = [];
    categories = [];
    notifyListeners();
  }

  Future<void> _clear() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _activeProfileKey);
  }

  void _handleUnauthorized() {
    if (api.token == null) return;
    logout().then((_) => onSessionExpired?.call());
  }

  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final results = await Future.wait([api.expenses(), api.categories()]);
      expenses = results[0] as List<Expense>;
      categories = results[1] as List<Category>;
    } on ApiException catch (e) {
      error = e.message;
    }
    loading = false;
    notifyListeners();
  }

  /// Fişi kaydeder ve taslaktaki bekleyen fotoğrafları yükler. Fiş kaydı fotoğraf yüklemesi
  /// başarısız olsa da korunur; fotoğraflar yüklenebildiyse true döner (yüklenemediyse çağıran
  /// kullanıcıya "fotoğraflar yüklenemedi, detaydan tekrar ekleyin" der).
  Future<bool> saveDraft(ReceiptDraft d) async {
    final body = {
      'merchant': d.merchant,
      'amount': d.items.fold<double>(0, (s, i) => s + i.amount),
      'date':
          '${d.date.year.toString().padLeft(4, '0')}-'
          '${d.date.month.toString().padLeft(2, '0')}-'
          '${d.date.day.toString().padLeft(2, '0')}',
      'category_id': d.categoryId,
      'note': d.note,
      'items': d.items.map((i) => i.toJson()).toList(),
    };
    final saved = d.id == null
        ? await api.createExpense(body)
        : await api.updateExpense(d.id!, body);
    var imagesOk = true;
    if (d.pendingImages.isNotEmpty) {
      try {
        await api.uploadImages(saved.id, d.pendingImages);
        // Yüklendi: bellekte gereksiz tutulmasın (FR-2.3 ruhu).
        for (final p in d.pendingImages) {
          p.fillRange(0, p.length, 0);
        }
        d.pendingImages = [];
      } on ApiException {
        imagesOk = false;
      }
    }
    await refresh(); // fotoğraf kimlikleri (image_ids) listede/detayda görünsün
    return imagesOk;
  }

  Future<void> deleteExpense(int id) async {
    await api.deleteExpense(id);
    await refresh();
  }

  /// Seçili OCR motoru stratejisiyle fiş sayfalarını tek çağrıda (JWT'li expense `/receipts/scan`)
  /// tarar ve ayrıştırır. Baytlar SIFIRLANMAZ: taslağa `pendingImages` olarak taşınır ve fiş
  /// kaydedilirken sunucuya yüklenir (yükleme sonrası `saveDraft` sıfırlar).
  Future<ScanResult> scanAndParseReceipt(
    List<Uint8List> pages, {
    String? engine,
  }) async {
    final ocrEngine = ocrFactory.resolve(api, engineName: engine);
    return ocrEngine.scan(pages);
  }
}

final appState = AppState();
