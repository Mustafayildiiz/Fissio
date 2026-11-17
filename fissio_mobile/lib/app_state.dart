import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;

import 'api.dart';
import 'data/connectivity.dart';
import 'data/local_store.dart';
import 'data/sync_service.dart';
import 'data/uid.dart';
import 'models.dart';
import 'ocr/ocr_engine.dart';
import 'ocr/on_device_ocr_engine.dart';
import 'theme_controller.dart';

/// [AppState.saveDraft] sonucu.
class SaveResult {
  /// Fotoğraflar kaydedildi (yüklendi ya da cihaza yazıldı).
  final bool imagesOk;

  /// Bulut senkronu açık ama bağlantı yoktu: fiş (ve fotoğraflar) cihaz kuyruğuna alındı, bağlantı gelince
  /// otomatik yüklenecek.
  final bool queued;

  /// Senkron kapalı: fiş yalnızca cihazda.
  final bool localOnly;
  const SaveResult({this.imagesOk = true, this.queued = false, this.localOnly = false});
}

const readOnlyCloudMessage =
    'Bulut senkronu kapalıyken bulut fişleri değiştirilemez. Ayarlar > Veri Yönetimi\'nden senkronu açın.';

/// Uygulama durumu. Hesap (`User`) → profiller → fişler; hepsi giriş yapan hesaba bağlıdır. Çıkış / hesap
/// değişiminde bellekteki tüm hesap verisi sıfırlanır.
///
/// Veri yeri: bulut senkronu AÇIKKEN (varsayılan) kayıtlar sunucuya gider; bağlantı yoksa cihaz kuyruğuna
/// ([SyncState.pending]) alınır ve bağlantı gelince otomatik yüklenir. KAPALIYKEN ([SyncState.localOnly])
/// hiçbir yazma isteği sunucuya gitmez.
class AppState extends ChangeNotifier {
  AppState({
    ApiClient? api,
    PrefsStore? store,
    LocalStore? local,
    ConnectivityMonitor? connectivity,
    this.backgroundInterval = const Duration(seconds: 60),
    DateTime Function()? clock,
    OcrEngine? onDeviceOcr,
    OcrMode Function()? ocrMode,
  }) : _store = store ?? const SecurePrefsStore(),
       _local = local ?? FileLocalStore(),
       _connectivity = connectivity ?? PluginConnectivity(),
       _clock = clock ?? DateTime.now,
       _ocrMode = ocrMode ?? (() => themeController.ocrMode) {
    _onDeviceOcr = onDeviceOcr ?? OnDeviceOcrEngine(otherCategoryId: _otherCategoryId);
    this.api = api ?? ApiClient();
    this.api.onUnauthorized = _handleUnauthorized;
    this.api.onTokensChanged = _persistTokens;
    this.api.onSuccess = _onApiSuccess;
    _sync = SyncService(
      api: this.api,
      local: _local,
      userId: () => user?.id,
      enabled: () => _syncEnabled,
      snapshot: () => _snap,
      onChanged: notifyListeners,
    );
  }

  late final ApiClient api;
  late final SyncService _sync;
  final PrefsStore _store;
  final LocalStore _local;
  final ConnectivityMonitor _connectivity;
  final DateTime Function() _clock;
  final Duration backgroundInterval;
  final OcrMode Function() _ocrMode;
  late final OcrEngine _onDeviceOcr;
  final OcrEngineFactory ocrFactory = OcrEngineFactory(defaultEngine: 'paddleocr');

  static const _tokensKey = 'auth_tokens';
  static const _userKey = 'auth_user';
  static String _activeKey(int uid) => 'active_profile:$uid';
  static String _syncKey(int uid) => 'sync_enabled:$uid';

  AuthUser? user;
  LocalSnapshot _snap = LocalSnapshot();
  List<Expense> _cloudExpenses = [];
  List<Category> categories = [];
  String? activeProfileId;
  bool _syncEnabled = true;
  bool loading = false;
  String? error;

  VoidCallback? onSessionExpired;

  Timer? _tick;
  StreamSubscription<bool>? _connSub;
  DateTime? _flushBackoffUntil;
  Future<void> _tokenWrites = Future.value();

  // --- Okunabilir durum ---

  bool get loggedIn => api.token != null && user != null;
  String? get email => user?.email;
  bool get syncEnabled => _syncEnabled;
  List<Profile> get profiles => List.unmodifiable(_snap.profiles);
  Profile? get activeProfile => _snap.profiles.where((p) => p.id == activeProfileId).firstOrNull;
  String? get profileName => activeProfile?.name;
  String get displayName => profileName ?? user?.name.nonEmpty ?? email ?? 'Profil';

  /// Bağlantı gelince buluta yüklenecek kayıt sayısı (senkron açık).
  int get pendingCount => _sync.pendingCount;

  /// Yalnızca cihazda kalan (senkron kapalıyken eklenen) fiş + profil sayısı.
  int get localOnlyCount =>
      _snap.expenses.where((e) => e.syncState == SyncState.localOnly).length +
      _snap.profiles.where((p) => p.state == SyncState.localOnly).length;

  /// Yüklenmemiş (pending + localOnly) kayıt var mı — çıkışta bilgilendirme için.
  bool get hasUnsyncedData => pendingCount + localOnlyCount > 0;

  /// Aktif profilin fişleri: sunucudakiler + cihazdakiler (tarihe göre, yeni üstte).
  List<Expense> get expenses {
    final pid = activeProfileId;
    final cloudUids = {for (final e in _cloudExpenses) e.clientUid};
    final out = <Expense>[
      ..._cloudExpenses.where((e) => e.profileUid == pid),
      // Sunucuda zaten olan fişin yerel kaydı yalnızca görsel kuyruğudur; listede tekrarlanmaz.
      ..._snap.expenses.where((e) => e.profileUid == pid && !cloudUids.contains(e.clientUid)),
    ];
    out.sort((a, b) {
      final c = b.date.compareTo(a.date);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
    return out;
  }

  /// Tüm profillerdeki tüm fişler (dışa aktarma için).
  List<Expense> get allExpenses {
    final cloudUids = {for (final e in _cloudExpenses) e.clientUid};
    return [
      ..._cloudExpenses,
      ..._snap.expenses.where((e) => !cloudUids.contains(e.clientUid)),
    ];
  }

  // --- Oturum ---

  Future<void> _wipeLegacy() async {
    // Eski sürüm: sentetik hesaplar ve düz metin şifreler. Artık hiç kullanılmaz; siliyoruz.
    for (final k in const ['jwt', 'profiles_v2', 'active_profile_v2']) {
      try {
        await _delete(k);
      } catch (_) {}
    }
  }

  Future<String?> _read(String key) async {
    final v = await _store.read(key);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> _write(String key, String value) => _store.write(key, value);

  Future<void> _delete(String key) {
    final s = _store;
    return s is DeletablePrefsStore ? s.delete(key) : s.write(key, '');
  }

  void _persistTokens(AuthTokens? t) {
    // Sıralı yaz: hızlı ardışık yenilemelerde eski değer yenisinin üzerine yazılmasın.
    _tokenWrites = _tokenWrites.then((_) async {
      try {
        if (t == null) {
          await _delete(_tokensKey);
        } else {
          await _write(
            _tokensKey,
            jsonEncode({
              'access': t.access,
              'refresh': t.refresh,
              'expires_at': t.expiresAt.toIso8601String(),
            }),
          );
        }
      } catch (_) {}
    });
  }

  /// Kayıtlı oturumu yükler. Ağ yoksa son bilinen hesapla çevrimdışı devam eder; sunucu oturumu geçersiz
  /// sayarsa (iptal/silinmiş hesap) yerel oturum temizlenir.
  Future<bool> restoreSession() async {
    await _wipeLegacy();
    try {
      final rawTokens = await _read(_tokensKey);
      final rawUser = await _read(_userKey);
      if (rawTokens == null || rawUser == null) return false;
      final t = jsonDecode(rawTokens) as Map<String, dynamic>;
      user = AuthUser.fromJson(jsonDecode(rawUser) as Map<String, dynamic>);
      api.setTokens(
        AuthTokens(
          access: t['access'] as String,
          refresh: t['refresh'] as String,
          expiresAt: DateTime.parse(t['expires_at'] as String),
        ),
        notify: false,
      );
    } catch (_) {
      await _localSignOut();
      return false;
    }
    await _loadAccountState();
    try {
      user = await api.me();
      await _write(_userKey, jsonEncode(user!.toJson()));
    } on ApiException catch (e) {
      if (!e.network) {
        // refresh de başarısızsa api zaten _handleUnauthorized'ı çağırmış olabilir.
        await _localSignOut();
        return false;
      }
      // çevrimdışı: yerel veriyle devam
    }
    if (!loggedIn) return false;
    _startBackground();
    await refresh();
    unawaited(flushNow());
    return true;
  }

  /// Hesap açıldı/giriş yapıldı: önceki hesabın tüm bellek durumu sıfırlanır.
  Future<void> _signIn(AuthSession s) async {
    _resetMemory();
    user = s.user;
    api.setTokens(s.tokens);
    await _write(_userKey, jsonEncode(s.user.toJson()));
    await _loadAccountState();
    _startBackground();
    notifyListeners();
    await refresh();
    unawaited(flushNow());
  }

  Future<void> _loadAccountState() async {
    final id = user!.id;
    _snap = await _local.load(id);
    categories = List.of(_snap.categories);
    _syncEnabled = (await _read(_syncKey(id))) != '0';
    activeProfileId = await _read(_activeKey(id));
    _cloudExpenses = [];
  }

  Future<void> login(String mail, String password) async {
    final s = await api.login(mail.trim(), password);
    await _signIn(s);
  }

  /// Kayıt: e-postaya doğrulama kodu gider; hesap kod doğrulanana kadar aktif değildir.
  /// Dönen değer "tekrar gönder" için beklenecek saniyedir.
  Future<int> register(String mail, String password, {String name = ''}) =>
      api.register(mail.trim(), password, name: name.trim());

  Future<void> verifyEmail(String mail, String code) async {
    final s = await api.verifyEmail(mail.trim(), code.trim());
    await _signIn(s);
  }

  Future<int> resendCode(String mail) => api.resendCode(mail.trim());
  Future<int> forgotPassword(String mail) => api.forgotPassword(mail.trim());
  Future<void> resetPassword(String mail, String code, String newPassword) =>
      api.resetPassword(mail.trim(), code.trim(), newPassword);

  /// Çıkış: sunucudaki bu cihaz oturumu kapatılır, bellekteki tüm hesap verisi, aktif profil seçimi ve token'lar
  /// silinir. (Cihazdaki yüklenmemiş fiş dosyası, aynı hesapla tekrar girişte geri gelsin diye diskte kalır.)
  Future<void> logout() async {
    try {
      await api.logout().timeout(const Duration(seconds: 4));
    } catch (_) {
      // çevrimdışıyken de yerelde çıkış yapılır
    }
    await _localSignOut();
  }

  /// Tüm cihazlardan çıkış (bu cihaz dahil).
  Future<void> logoutEverywhere() async {
    await api.logoutAll();
    await _localSignOut();
  }

  /// KVKK/GDPR: şifre onayıyla hesabı, tüm profil/fiş/görsel/oturumları sunucuda ve cihazdaki yerel verileri siler.
  Future<void> deleteAccount(String password) async {
    final id = user?.id;
    await api.deleteAccount(password);
    if (id != null) {
      await _local.deleteAll(id);
      await _delete(_syncKey(id));
      await _delete(_activeKey(id));
    }
    await _localSignOut();
  }

  Future<void> _localSignOut() async {
    _stopBackground();
    final id = user?.id;
    api.setTokens(null, notify: false);
    await _tokenWrites;
    await _delete(_tokensKey);
    await _delete(_userKey);
    if (id != null) await _delete(_activeKey(id));
    _resetMemory();
    notifyListeners();
  }

  void _resetMemory() {
    user = null;
    _snap = LocalSnapshot();
    _cloudExpenses = [];
    categories = [];
    activeProfileId = null;
    _syncEnabled = true;
    loading = false;
    error = null;
    _flushBackoffUntil = null;
  }

  void _handleUnauthorized() {
    if (user == null) return;
    _localSignOut().then((_) => onSessionExpired?.call());
  }

  // --- Arka plan: token ön yenileme + çevrimdışı kuyruk ---

  void _startBackground() {
    _stopBackground();
    _tick = Timer.periodic(backgroundInterval, (_) {
      api.ensureFresh();
      unawaited(flushNow());
    });
    try {
      _connSub = _connectivity.onChanged.listen((online) {
        if (online) unawaited(flushNow(force: true));
      });
    } catch (_) {
      // eklenti yoksa (test/masaüstü) yalnızca zamanlayıcı ve uygulama-öne-gelme tetikler
    }
  }

  void _stopBackground() {
    _tick?.cancel();
    _tick = null;
    _connSub?.cancel();
    _connSub = null;
  }

  /// Uygulama ön plana gelince: token'ı yenile ve kuyruğu boşalt.
  Future<void> onAppResumed() async {
    if (!loggedIn) return;
    await api.ensureFresh();
    await flushNow(force: true);
  }

  /// Her başarılı API isteğinden sonra, kuyrukta kayıt varsa boşaltmayı dener (bağlantı geri geldi demektir).
  void _onApiSuccess() {
    if (_syncEnabled && !_sync.flushing && _sync.hasWork) {
      scheduleMicrotask(() => flushNow());
    }
  }

  /// Çevrimdışı kuyruğu buluta boşaltır ([force] = tekrar deneme bekleme süresini yok say).
  Future<FlushOutcome> flushNow({bool force = false}) async {
    if (!loggedIn) return FlushOutcome.nothing;
    final until = _flushBackoffUntil;
    if (!force && until != null && _clock().isBefore(until)) return FlushOutcome.busy;
    final o = await _sync.flush();
    if (o == FlushOutcome.partial) {
      _flushBackoffUntil = _clock().add(const Duration(seconds: 60));
    }
    if (o == FlushOutcome.done || o == FlushOutcome.partial) {
      await refresh();
    }
    return o;
  }

  // --- Bulut senkronu ---

  /// Senkronu aç/kapat. Kapatınca bekleyen kuyruk da yerele çekilir (artık hiçbir şey gönderilmez); açınca
  /// cihazdaki kayıtlar yüklenir (client_uid ile idempotent).
  Future<void> setSyncEnabled(bool value) async {
    final id = user?.id;
    if (id == null || value == _syncEnabled) return;
    _syncEnabled = value;
    await _write(_syncKey(id), value ? '1' : '0');
    final from = value ? SyncState.localOnly : SyncState.pending;
    final to = value ? SyncState.pending : SyncState.localOnly;
    _snap.profiles = [for (final p in _snap.profiles) p.state == from ? p.copyWith(state: to) : p];
    _snap.expenses = [for (final e in _snap.expenses) e.syncState == from ? e.copyWith(syncState: to) : e];
    await _persistSnapshot();
    notifyListeners();
    if (value) await flushNow(force: true);
  }

  Future<void> _persistSnapshot() async {
    final id = user?.id;
    if (id != null) await _local.save(id, _snap);
  }

  // --- Veri yükleme ---

  Future<void> refresh() async {
    if (!loggedIn) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final cats = await api.categories();
      final ps = await api.profiles();
      final ex = await api.expenses();
      categories = cats;
      _snap.categories = cats;
      _applyCloud(ps, ex);
      await _persistSnapshot();
    } on ApiException catch (e) {
      error = e.message;
    }
    loading = false;
    notifyListeners();
  }

  void _applyCloud(List<Profile> serverProfiles, List<Expense> serverExpenses) {
    final byServerId = {for (final p in serverProfiles) p.serverId: p.id};
    final serverUids = {for (final p in serverProfiles) p.id};
    // Sunucuda artık var olan yerel (pending) profil çift görünmesin; sunucu kazanır.
    final local = _snap.profiles.where((p) => p.state != SyncState.synced && !serverUids.contains(p.id));
    // Cihazdaki (henüz yüklenmemiş) avatar yolu sunucu yanıtıyla ezilmesin.
    final localAvatars = {for (final p in _snap.profiles) p.id: p.localAvatarPath};
    _snap.profiles = [
      for (final p in serverProfiles)
        localAvatars[p.id] == null ? p : p.copyWith(localAvatarPath: localAvatars[p.id]),
      ...local,
    ];
    _cloudExpenses = [
      for (final e in serverExpenses) e.copyWith(profileUid: byServerId[e.profileServerId] ?? ''),
    ];
    if (activeProfileId == null || !_snap.profiles.any((p) => p.id == activeProfileId)) {
      activeProfileId = _snap.profiles.firstOrNull?.id;
      final id = user?.id;
      if (id != null && activeProfileId != null) _write(_activeKey(id), activeProfileId!);
    }
  }

  // --- Profiller ---

  Future<void> selectProfile(Profile p) async {
    activeProfileId = p.id;
    final id = user?.id;
    if (id != null) await _write(_activeKey(id), p.id);
    notifyListeners();
  }

  /// Hesabın altına yeni profil (Ev, İş, Ortak...). Senkron açıksa sunucuda oluşur; bağlantı yoksa kuyruğa
  /// alınır; senkron kapalıysa yalnızca cihazda kalır.
  Future<void> createProfile(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final uid = newClientUid('p');
    Profile created;
    if (_syncEnabled) {
      try {
        created = await api.createProfile(trimmed, clientUid: uid);
      } on ApiException catch (e) {
        if (!e.network) rethrow;
        created = Profile(id: uid, name: trimmed, state: SyncState.pending);
      }
    } else {
      created = Profile(id: uid, name: trimmed, state: SyncState.localOnly);
    }
    _snap.profiles = [..._snap.profiles, created];
    await _persistSnapshot();
    await selectProfile(created);
  }

  Profile? _profile(String id) => _snap.profiles.where((p) => p.id == id).firstOrNull;

  Future<void> renameProfile(String id, String newName) async {
    final trimmed = newName.trim();
    final p = _profile(id);
    if (trimmed.isEmpty || p == null) return;
    if (p.state == SyncState.synced) {
      if (!_syncEnabled) throw ApiException(readOnlyCloudMessage);
      await api.renameProfile(p.serverId!, trimmed);
    }
    _snap.profiles = [for (final x in _snap.profiles) x.id == id ? x.copyWith(name: trimmed) : x];
    await _persistSnapshot();
    notifyListeners();
  }

  /// Profil fotoğrafını ayarlar ([bytes] istemcide ~512px JPEG'e küçültülmüş olmalı). Senkron açık ve
  /// çevrimiçiyse sunucuya yüklenir; senkron kapalı / çevrimdışı / profil henüz yüklenmemişse cihazda tutulur
  /// ve senkron açıkken otomatik yüklenir.
  Future<void> setProfileAvatar(String id, Uint8List bytes) async {
    final p = _profile(id);
    final uid = user?.id;
    if (p == null || uid == null || bytes.isEmpty) return;
    Profile next;
    var uploaded = false;
    if (_syncEnabled && p.serverId != null) {
      try {
        final v = await api.uploadAvatar(p.serverId!, bytes);
        next = p.copyWith(avatarVersion: v, clearLocalAvatar: true);
        uploaded = true;
      } on ApiException catch (e) {
        if (!e.network) rethrow;
        next = p;
      }
    } else {
      next = p;
    }
    if (!uploaded) {
      next = p.copyWith(localAvatarPath: await _local.saveImage(uid, bytes));
    }
    if (p.localAvatarPath != null) await _local.deleteImage(p.localAvatarPath!);
    _snap.profiles = [for (final x in _snap.profiles) x.id == id ? next : x];
    await _persistSnapshot();
    notifyListeners();
  }

  /// Profil fotoğrafını kaldırır (varsayılan baş harf avatarına döner).
  Future<void> removeProfileAvatar(String id) async {
    final p = _profile(id);
    if (p == null) return;
    if (p.serverId != null && p.avatarVersion > 0) {
      if (!_syncEnabled) throw ApiException(readOnlyCloudMessage);
      await api.deleteAvatar(p.serverId!);
    }
    if (p.localAvatarPath != null) await _local.deleteImage(p.localAvatarPath!);
    _snap.profiles = [
      for (final x in _snap.profiles) x.id == id ? x.copyWith(avatarVersion: 0, clearLocalAvatar: true) : x,
    ];
    await _persistSnapshot();
    notifyListeners();
  }

  /// Profili ve içindeki tüm fişleri siler (en az 1 profil kalmalıdır).
  Future<void> deleteProfile(String id) async {
    final p = _profile(id);
    if (p == null || _snap.profiles.length <= 1) return;
    if (p.state == SyncState.synced) {
      if (!_syncEnabled) throw ApiException(readOnlyCloudMessage);
      await api.deleteProfile(p.serverId!);
    }
    if (p.localAvatarPath != null) await _local.deleteImage(p.localAvatarPath!);
    for (final e in _snap.expenses.where((e) => e.profileUid == id)) {
      for (final path in e.localImages) {
        await _local.deleteImage(path);
      }
    }
    _snap.expenses = _snap.expenses.where((e) => e.profileUid != id).toList();
    _snap.profiles = _snap.profiles.where((x) => x.id != id).toList();
    _cloudExpenses = _cloudExpenses.where((e) => e.profileUid != id).toList();
    await _persistSnapshot();
    if (activeProfileId == id) {
      await selectProfile(_snap.profiles.first);
    } else {
      notifyListeners();
    }
  }

  // --- Fişler ---

  String? _categoryName(int? id) => categories.where((c) => c.id == id).map((c) => c.name).firstOrNull;

  /// Fişi kaydeder. Senkron açık + bağlantı varsa sunucuya; bağlantı yoksa cihaz kuyruğuna (kaybolmaz,
  /// bağlantı gelince yüklenir); senkron kapalıysa yalnızca cihaza. Fotoğraflar fişle birlikte aynı yola gider.
  Future<SaveResult> saveDraft(ReceiptDraft d) async {
    final profile = activeProfile;
    if (profile == null) throw ApiException('Önce bir profil seçin.');

    // Cihazdaki (yüklenmemiş) fişi düzenleme.
    if (d.id != null && d.id! < 0) return _updateLocal(d);

    // Sunucudaki fişi düzenleme: yalnızca senkron açıkken.
    if (d.id != null) {
      if (!_syncEnabled) throw ApiException(readOnlyCloudMessage);
      final saved = await api.updateExpense(d.id!, d.toRequestBody());
      final ok = await _uploadPending(saved.id, d);
      await refresh();
      return SaveResult(imagesOk: ok);
    }

    // Yeni fiş.
    d.clientUid ??= newClientUid();
    if (!_syncEnabled) {
      await _queueLocal(d, profile, SyncState.localOnly);
      return const SaveResult(localOnly: true);
    }
    if (profile.serverId == null) {
      // Profil henüz sunucuda yok (çevrimdışı oluşturuldu): fiş de kuyruğa.
      await _queueLocal(d, profile, SyncState.pending);
      unawaited(flushNow(force: true));
      return const SaveResult(queued: true);
    }
    final body = d.toRequestBody()..['profile_id'] = profile.serverId;
    final Expense saved;
    try {
      saved = await api.createExpense(body);
    } on ApiException catch (e) {
      if (!e.network) rethrow;
      await _queueLocal(d, profile, SyncState.pending);
      return const SaveResult(queued: true);
    }
    var imagesOk = true;
    var queued = false;
    if (d.pendingImages.isNotEmpty) {
      try {
        await api.uploadImages(saved.id, d.pendingImages);
        _zero(d);
      } on ApiException catch (e) {
        if (e.network) {
          // Fiş sunucuda, görseller değil: aynı client_uid ile görsel kuyruğu (tekrarlanmaz).
          await _queueLocal(d, profile, SyncState.pending);
          queued = true;
        } else {
          imagesOk = false;
        }
      }
    }
    await refresh(); // fotoğraf kimlikleri (image_ids) listede/detayda görünsün
    return SaveResult(imagesOk: imagesOk, queued: queued);
  }

  Future<bool> _uploadPending(int expenseId, ReceiptDraft d) async {
    if (d.pendingImages.isEmpty) return true;
    try {
      await api.uploadImages(expenseId, d.pendingImages);
      _zero(d);
      return true;
    } on ApiException {
      return false;
    }
  }

  void _zero(ReceiptDraft d) {
    // Yüklendi: bellekte gereksiz tutulmasın (FR-2.3 ruhu).
    for (final p in d.pendingImages) {
      p.fillRange(0, p.length, 0);
    }
    d.pendingImages = [];
  }

  Future<List<String>> _storeImages(List<Uint8List> images) async {
    final id = user!.id;
    return [for (final b in images) await _local.saveImage(id, b)];
  }

  Expense _fromDraft(ReceiptDraft d, {required int id, required Profile profile, required SyncState state, List<String> images = const []}) {
    final cid = d.categoryId ?? 0;
    return Expense(
      id: id,
      merchant: d.merchant,
      amount: d.savedAmount,
      date: d.date,
      categoryId: cid,
      categoryName: _categoryName(cid) ?? 'Diğer',
      note: d.note,
      items: [
        for (final i in d.items)
          ExpenseItem(
            i.name,
            i.amount,
            categoryId: i.categoryId,
            categoryName: i.categoryName ?? _categoryName(i.categoryId),
            suggestedCategoryId: i.suggestedCategoryId,
          ),
      ],
      clientUid: d.clientUid!,
      profileUid: profile.id,
      profileServerId: profile.serverId,
      syncState: state,
      localImages: images,
      suggestedCategoryId: d.suggestedCategoryId,
    );
  }

  Future<void> _queueLocal(ReceiptDraft d, Profile profile, SyncState state) async {
    final images = await _storeImages(d.pendingImages);
    _zero(d);
    _snap.expenses = [
      ..._snap.expenses.where((e) => e.clientUid != d.clientUid),
      _fromDraft(d, id: _snap.nextLocalId(), profile: profile, state: state, images: images),
    ];
    await _persistSnapshot();
    notifyListeners();
  }

  Future<SaveResult> _updateLocal(ReceiptDraft d) async {
    final old = _snap.expenses.where((e) => e.id == d.id).firstOrNull;
    if (old == null) throw ApiException('Fiş bulunamadı.');
    final extra = await _storeImages(d.pendingImages);
    _zero(d);
    d.clientUid = old.clientUid;
    final updated = _fromDraft(
      d,
      id: old.id,
      profile: _profile(old.profileUid) ?? activeProfile!,
      state: old.syncState,
      images: [...old.localImages, ...extra],
    );
    _snap.expenses = [for (final e in _snap.expenses) e.id == old.id ? updated : e];
    await _persistSnapshot();
    notifyListeners();
    return SaveResult(localOnly: old.syncState == SyncState.localOnly, queued: old.syncState == SyncState.pending);
  }

  Future<void> deleteExpense(int id) async {
    if (id < 0) {
      final e = _snap.expenses.where((x) => x.id == id).firstOrNull;
      if (e != null) {
        for (final p in e.localImages) {
          await _local.deleteImage(p);
        }
      }
      _snap.expenses = _snap.expenses.where((x) => x.id != id).toList();
      await _persistSnapshot();
      notifyListeners();
      return;
    }
    if (!_syncEnabled) throw ApiException(readOnlyCloudMessage);
    await api.deleteExpense(id);
    await refresh();
  }

  // --- Fotoğraflar (detay ekranı) ---

  /// Fişe fotoğraf ekler: sunucudaki fişe yüklenir (senkron açıkken), cihazdaki fişe cihaza yazılır.
  Future<void> addImages(Expense e, List<Uint8List> images) async {
    if (e.id < 0) {
      final paths = await _storeImages(images);
      _snap.expenses = [
        for (final x in _snap.expenses) x.id == e.id ? x.copyWith(localImages: [...x.localImages, ...paths]) : x,
      ];
      await _persistSnapshot();
      notifyListeners();
      return;
    }
    if (!_syncEnabled) throw ApiException(readOnlyCloudMessage);
    await api.uploadImages(e.id, images);
    await refresh();
  }

  Future<void> removeCloudImage(int expenseId, int imageId) async {
    if (!_syncEnabled) throw ApiException(readOnlyCloudMessage);
    await api.deleteImage(expenseId, imageId);
    await refresh();
  }

  Future<void> removeLocalImage(int expenseId, String path) async {
    await _local.deleteImage(path);
    _snap.expenses = [
      for (final x in _snap.expenses)
        x.id == expenseId ? x.copyWith(localImages: x.localImages.where((p) => p != path).toList()) : x,
    ];
    await _persistSnapshot();
    notifyListeners();
  }

  /// Cihazdaki fotoğrafı okur (önizleme).
  Future<Uint8List?> readLocalImage(String path) => _local.readImage(path);

  // --- İçe aktarma (data_transfer.dart) ---

  /// İçe aktarılan fişleri cihaz kuyruğuna ekler ve (senkron açıksa) idempotent olarak buluta yükler.
  /// [profileName] mevcut bir profille (uid ya da ad) eşleşirse o profile, yoksa yeni profile yazılır.
  Future<Profile> ensureProfileForImport({required String uid, required String name}) async {
    final byUid = _profile(uid);
    if (byUid != null) return byUid;
    final byName = _snap.profiles.where((p) => p.name.toLowerCase() == name.trim().toLowerCase()).firstOrNull;
    if (byName != null) return byName;
    final state = _syncEnabled ? SyncState.pending : SyncState.localOnly;
    final p = Profile(id: uid, name: name.trim().isEmpty ? 'İçe aktarılan' : name.trim(), state: state);
    _snap.profiles = [..._snap.profiles, p];
    await _persistSnapshot();
    notifyListeners();
    return p;
  }

  /// İçe aktarılan fişi kuyruğa ekler (zaten var olanlar çağıran tarafından elenir).
  Future<void> addImportedExpense(Expense e) async {
    final state = _syncEnabled ? SyncState.pending : SyncState.localOnly;
    _snap.expenses = [..._snap.expenses, e.copyWith(id: _snap.nextLocalId(), syncState: state)];
  }

  /// Toplu içe aktarma sonrası: kaydet, bildir ve (senkron açıksa) yükle.
  Future<void> finishImport() async {
    await _persistSnapshot();
    notifyListeners();
    if (_syncEnabled) await flushNow(force: true);
  }

  int? _otherCategoryId() => categories.where((c) => c.name == 'Diğer').firstOrNull?.id;

  /// Taramada cihaz içi OCR mı kullanılacak? Senkron kapalıysa her zaman; `onDevice` her zaman; `server`
  /// hiçbir zaman (ağ hatası hariç); `auto` yalnızca bağlantı yokken.
  Future<bool> _preferOnDeviceOcr() async {
    // Bulut senkronu kapalıyken hiçbir seçimde fotoğraf sunucuya gönderilmez.
    if (!_syncEnabled) return true;
    switch (_ocrMode()) {
      case OcrMode.onDevice:
        return true;
      case OcrMode.server:
        return false;
      case OcrMode.auto:
        try {
          return !await _connectivity.isOnline();
        } catch (_) {
          return false;
        }
    }
  }

  /// Fişi okur ve ayrıştırır. Sunucu OCR'ı denenirken ağ hatası olursa (bağlantı yok / sunucuya ulaşılamıyor)
  /// hata vermeden cihaz içi OCR'a düşer; doğrulama gibi ağ dışı hatalar olduğu gibi iletilir.
  Future<ScanResult> scanAndParseReceipt(List<Uint8List> pages, {String? engine}) async {
    if (await _preferOnDeviceOcr()) return _onDeviceOcr.scan(pages);
    final ocrEngine = ocrFactory.resolve(api, engineName: engine);
    try {
      return await ocrEngine.scan(pages);
    } on ApiException catch (e) {
      if (!e.network) rethrow;
      return _onDeviceOcr.scan(pages);
    }
  }

  @override
  void dispose() {
    _stopBackground();
    super.dispose();
  }
}

extension on String {
  String? get nonEmpty => isEmpty ? null : this;
}

final appState = AppState();
