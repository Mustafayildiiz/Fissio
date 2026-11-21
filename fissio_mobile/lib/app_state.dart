import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemException, Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;

import 'api.dart';
import 'budgets.dart';
import 'data/connectivity.dart';
import 'data/image_disk_cache.dart';
import 'data/local_store.dart';
import 'data/sync_service.dart';
import 'data/uid.dart';
import 'models.dart';
import 'ocr/ocr_engine.dart';
import 'ocr/on_device_ocr_engine.dart';
import 'receipt_parser/digital_ids.dart';
import 'receipt_parser/digital_receipt.dart';
import 'receipt_parser/eml.dart';
import 'receipt_parser/html_text.dart';
import 'receipt_parser/merge.dart' show mergePageTexts;
import 'receipt_parser/parser.dart' show parseReceiptText;
import 'receipt_parser/normalize.dart' show foldTR;
import 'recurring.dart';
import 'services/notifier.dart';
import 'services/pdf_reader.dart';
import 'services/widget_sync.dart';
import 'theme.dart' show fmtMoney, kMonthNames;
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

  /// Resmi fatura yeni kayıt açmadı: mevcut bir ön özet (sipariş özeti) kaydına işlendi ve kilitlendi.
  final bool merged;
  const SaveResult({this.imagesOk = true, this.queued = false, this.localOnly = false, this.merged = false});

  SaveResult asMerged() => SaveResult(imagesOk: imagesOk, queued: queued, localOnly: localOnly, merged: true);
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
    LocalNotifier? notifier,
    WidgetSync? widgetSync,
  }) : _store = store ?? const SecurePrefsStore(),
       notifier = notifier ?? PluginLocalNotifier(),
       _widget = widgetSync ?? PluginWidgetSync(),
       _local = local ?? FileLocalStore(),
       _connectivity = connectivity ?? PluginConnectivity(),
       _clock = clock ?? DateTime.now,
       _ocrMode = ocrMode ?? (() => themeController.ocrMode) {
    _onDeviceOcr = onDeviceOcr ?? OnDeviceOcrEngine(otherCategoryId: _otherCategoryId);
    this.api = api ?? ApiClient();
    this.api.onUnauthorized = _handleUnauthorized;
    this.api.onTokensChanged = _persistTokens;
    this.api.onSuccess = _onApiSuccess;
    // Widget renk teması / marka rengi değişince native widget'lar anında yeniden çizilir (oturumdan bağımsız).
    themeController.addListener(_pushWidgetTheme);
    scheduleMicrotask(_pushWidgetTheme);
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

  /// Yerel bildirimler (bütçe eşikleri, ödeme hatırlatıcıları) ve ana ekran widget'ı; testlerde sahteleri verilir.
  final LocalNotifier notifier;
  final WidgetSync _widget;
  final OcrEngineFactory ocrFactory = OcrEngineFactory(defaultEngine: 'paddleocr');

  static const _tokensKey = 'auth_tokens';
  static const _userKey = 'auth_user';
  static String _activeKey(int uid) => 'active_profile:$uid';
  static String _syncKey(int uid) => 'sync_enabled:$uid';
  static String _alertsKey(int uid) => 'budget_alerts:$uid';
  static String _emailCardKey(int uid) => 'email_card_dismissed:$uid';
  static String _emailSeenKey(int uid) => 'email_import_seen:$uid';

  AuthUser? user;
  LocalSnapshot _snap = LocalSnapshot();
  List<Category> categories = [];
  String? activeProfileId;
  bool _syncEnabled = true;

  /// Bu hesapta bu ay gönderilmiş bütçe bildirimleri (bkz. [budgetAlertKey]); tekrar bildirimi önler.
  Set<String> _alertsSent = {};
  bool loading = false;
  String? error;

  /// Son yenileme bağlantı yüzünden başarısız oldu: ekranlar cihazdaki son (önbellek) veriyi gösterir.
  bool offline = false;

  /// Cihazın bir ağa bağlı olup olmadığı ([ConnectivityMonitor]); internet/sunucu erişimi garantisi değildir.
  /// Durum rozeti bağlantı kopunca hemen görünsün diye [offline] ile birlikte kullanılır.
  bool connected = true;

  /// Bulut senkronu açıkken bağlantı sorunu var mı (durum rozeti için).
  bool get connectionTrouble => _syncEnabled && (offline || !connected);

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
  int get pendingCount => _sync.pendingCount + _sync.pendingBudgetCount + _sync.pendingChangeCount;

  /// Sunucunun kabul etmediği / gönderilemeyen kuyruk kaydı sayısı (kullanıcı düzenleyebilir ya da silebilir).
  int get failedSyncCount => _sync.failedCount;

  /// Sunucuda o arada (başka cihazda) değişmiş fişlere yapılmış, gönderilmeyen çevrimdışı düzenleme sayısı
  /// (bkz. [resolveEditConflict]).
  int get conflictedEditCount => _sync.conflictedEditCount;

  /// Çakışan düzenlemeler: kullanıcının hali ve (biliniyorsa) sunucudaki güncel hali.
  List<({Expense mine, Expense? server})> get editConflicts => [
    for (final e in _snap.pendingEdits)
      if (e.isEditConflict) (mine: e, server: _snap.cloudExpenses.where((x) => x.id == e.id).firstOrNull),
  ];

  /// Çakışmayı çözer. [keepMine]: düzenleme sunucudaki GÜNCEL sürümün üstüne yazılmak üzere yeniden kuyruğa alınır
  /// (ve hemen gönderilmeye çalışılır); aksi halde düzenleme (ve ona eklenmiş cihaz fotoğrafları) atılır, sunucudaki
  /// hal kalır.
  Future<void> resolveEditConflict(int id, {required bool keepMine}) async {
    final i = _snap.pendingEdits.indexWhere((e) => e.id == id && e.isEditConflict);
    if (i < 0) return;
    final edit = _snap.pendingEdits[i];
    if (keepMine) {
      final server = _snap.cloudExpenses.where((e) => e.id == id).firstOrNull;
      _snap.pendingEdits[i] = edit.copyWith(clearSyncError: true, updatedAt: server?.updatedAt);
    } else {
      for (final p in edit.localImages) {
        await _local.deleteImage(p);
      }
      _snap.pendingEdits = _snap.pendingEdits.where((e) => e.id != id).toList();
    }
    await _persistSnapshot();
    notifyListeners();
    // _exclusive yeniden girilir değil: gönderim, durum değişikliği bittikten sonra ayrı çağrıyla.
    if (keepMine && _syncEnabled) await flushNow(force: true);
  }

  /// Yalnızca cihazda kalan (senkron kapalıyken eklenen) fiş + profil sayısı.
  int get localOnlyCount =>
      _snap.expenses.where((e) => e.syncState == SyncState.localOnly).length +
      _snap.profiles.where((p) => p.state == SyncState.localOnly).length +
      _snap.budgets.where((b) => b.state == SyncState.localOnly).length;

  /// Yüklenmemiş (pending + localOnly) kayıt var mı — çıkışta bilgilendirme için.
  bool get hasUnsyncedData => pendingCount + localOnlyCount > 0;

  /// Sunucudan çekilen fişlerin cihazdaki son hali (çevrimdışı açılışta gösterilir) + yüklenmeyi bekleyen
  /// düzenlemeler üstüne işlenmiş, bekleyen silmeler çıkarılmış görünüm.
  List<Expense> get _cloudExpenses {
    if (_snap.pendingEdits.isEmpty && _snap.pendingDeletes.isEmpty) return _snap.cloudExpenses;
    final edits = {for (final e in _snap.pendingEdits) e.id: e};
    final deleted = _snap.pendingDeletes.toSet();
    return [
      for (final e in _snap.cloudExpenses)
        if (!deleted.contains(e.id)) edits[e.id] ?? e,
    ];
  }

  List<Expense> _activeUnsorted() {
    final pid = activeProfileId;
    final cloudUids = {for (final e in _cloudExpenses) e.clientUid};
    return <Expense>[
      ..._cloudExpenses.where((e) => e.profileUid == pid),
      // Sunucuda zaten olan fişin yerel kaydı yalnızca görsel kuyruğudur; listede tekrarlanmaz.
      ..._snap.expenses.where((e) => e.profileUid == pid && !cloudUids.contains(e.clientUid)),
    ];
  }

  /// Aktif profilin fişleri: sunucudakiler + cihazdakiler (tarihe göre, yeni üstte).
  List<Expense> get expenses {
    final out = _activeUnsorted();
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
    _emailCardDismissed = (await _read(_emailCardKey(id))) == '1';
    _emailImportSeen = (await _read(_emailSeenKey(id))) == '1';
    activeProfileId = await _read(_activeKey(id));
    _alertsSent = {};
    try {
      final raw = await _read(_alertsKey(id));
      if (raw != null) _alertsSent = {...(jsonDecode(raw) as List).cast<String>()};
    } catch (_) {}
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
    // ÖNCE oturumu bellekte kapat (arka plan flush durur, uçuştaki flush `stale()` olur), SONRA yerel veriyi sil: aksi halde
    // silme sürerken biten bir flush `_persist` ile hesabın yerel verisini diske geri yazabilirdi (silme adımı çoğaldıkça pencere büyür).
    // `dropCache: false`: yerel veri zaten silinecek, çıkış yolu diske ayrıca bir şey yazmasın.
    await _localSignOut(dropCache: false);
    if (id != null) {
      await _local.deleteAll(id);
      await _delete(_syncKey(id));
      await _delete(_activeKey(id));
      await _delete(_alertsKey(id));
      await _delete(_emailCardKey(id));
      await _delete(_emailSeenKey(id));
    }
  }

  Future<void> _localSignOut({bool dropCache = true}) async {
    _stopBackground();
    final id = user?.id;
    api.setTokens(null, notify: false);
    await _tokenWrites;
    await _delete(_tokensKey);
    await _delete(_userKey);
    if (id != null) await _delete(_activeKey(id));
    if (id != null && dropCache) await _dropCloudCache(id);
    // Önbellekteki fiş fotoğrafları / avatarlar da hesaba aittir: sonraki kullanıcıya kalmasın.
    if (dropCache) await ImageDiskCache.instance.clear();
    _resetMemory();
    notifyListeners();
    // Sonraki hesap önceki kullanıcının harcamasını / hatırlatıcılarını görmesin.
    await _clearDerivedOutputs();
  }

  /// Çıkışta sunucudan önbelleğe alınmış fişler/limitler diskte bırakılmaz (paylaşılan cihaz gizliliği); girişte
  /// yeniden çekilir. Yüklenmemiş kayıtlar (kuyruk, bekleyen düzenleme/silme) kaybolmasın diye kalır.
  Future<void> _dropCloudCache(int id) async {
    try {
      _snap.cloudExpenses = [];
      _snap.cloudSyncedAt = null; // önbelleksiz artımlı yenileme geçmişi gizlerdi: sonraki giriş tam çeker
      _snap.budgets = _snap.budgets.where((b) => b.state != SyncState.synced).toList();
      await _local.save(id, _snap);
    } catch (_) {}
  }

  void _resetMemory() {
    user = null;
    _snap = LocalSnapshot();
    offline = false;
    categories = [];
    activeProfileId = null;
    _syncEnabled = true;
    _inbound = null;
    _emailCardDismissed = false;
    _emailImportSeen = false;
    _alertsSent = {};
    loading = false;
    error = null;
    _flushBackoffUntil = null;
    _flushFailures = 0;
    _needsRefresh = false;
  }

  void _handleUnauthorized() {
    if (user == null) return;
    _localSignOut().then((_) => onSessionExpired?.call());
  }

  // --- Arka plan: token ön yenileme + çevrimdışı kuyruk ---

  void _startBackground() {
    _stopBackground();
    _dayKey = _todayKey();
    _tick = Timer.periodic(backgroundInterval, (_) {
      _checkDayRollover();
      api.ensureFresh();
      unawaited(flushNow());
    });
    try {
      _connSub = _connectivity.onChanged.listen((online) {
        if (connected != online) {
          connected = online;
          notifyListeners();
        }
        if (online) {
          unawaited(flushNow(force: true));
          // Ağ geldi ama sunucuya ulaşılabildiği henüz kanıtlanmadı: `offline` elle sıfırlanmaz, yenilemenin
          // sonucu (başarı/başarısızlık) belirler.
          if (offline) unawaited(refresh());
        }
      });
      unawaited(
        _connectivity.isOnline().then((v) {
          if (connected != v) {
            connected = v;
            notifyListeners();
          }
        }),
      );
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
    _checkDayRollover();
    await api.ensureFresh();
    await flushNow(force: true);
  }

  String _dayKey = '';
  String _todayKey() {
    final n = _clock();
    return '${n.year}-${n.month}-${n.day}';
  }

  /// Gün (dolayısıyla ay) değiştiyse dinleyicileri uyandırır: bütçe/sabit gider/yaklaşan ödeme/widget türevleri
  /// `_clock()` ile hesaplandığı için başka bir olay olmadan eski günde kalırdı (gece yarısı, ay dönümü).
  void _checkDayRollover() {
    final k = _todayKey();
    if (_dayKey.isNotEmpty && k != _dayKey) {
      _dayKey = k;
      notifyListeners();
    } else {
      _dayKey = k;
    }
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
    // refresh() ile aynı sıraya girer: sunucu listesi çekilirken kuyruk boşalıp (ör. profil "synced" olup) bayat
    // bir listeyle ezilmesin. Kilit refresh'in içinde alınır; burada iç içe geçmez.
    final o = await _exclusive(_sync.flush);
    if (o == FlushOutcome.partial) {
      // Üstel geri çekilme: kalıcı reddedilen bir kayıt her 60 sn'de tüm geçmişi indirtmesin (60 sn → en çok 15 dk).
      _flushFailures++;
      const steps = [60, 120, 240, 480, 900];
      final secs = steps[_flushFailures > steps.length ? steps.length - 1 : _flushFailures - 1];
      _flushBackoffUntil = _clock().add(Duration(seconds: secs));
    } else if (o == FlushOutcome.done || o == FlushOutcome.nothing) {
      _flushFailures = 0;
      _flushBackoffUntil = null;
    }
    // Hiçbir kayıt ilerlemediyse (aynı hata tekrarlandı) sunucudan yeniden indirmenin anlamı yok.
    if (o == FlushOutcome.done || (o == FlushOutcome.partial && _sync.progressed)) _needsRefresh = true;
    // Eşzamanlı başka bir flushNow kuyruğu boşaltmış olabilir (bu çağrı "nothing" görür); yine de dönmeden önce
    // o çalışmanın getirdiği değişiklikler sunucudan çekilmiş olsun.
    if (_needsRefresh) await _refreshIfNeeded();
    return o;
  }

  /// Kuyruk boşaldı ama sunucudaki liste henüz yeniden çekilmedi.
  bool _needsRefresh = false;
  Future<void> _refreshIfNeeded() => _exclusive(() async {
    if (_needsRefresh) await _refreshNow();
  });

  /// Ağ yazma/okuma işlemlerini (refresh, flush) sıraya dizer; aynı anda yalnızca biri çalışır. Future zinciri
  /// yerine bekleyen başına bir Completer kullanılır: her bekleyen KENDİ zone'unda uyanır (testlerde gerçek ve
  /// sahte asenkron bölgeler karışsa da kilit takılmaz). İşlem içinden tekrar [_exclusive] çağrılmaz.
  bool _exclusiveBusy = false;
  final List<Completer<void>> _exclusiveWaiters = [];
  Future<T> _exclusive<T>(Future<T> Function() op) async {
    if (_exclusiveBusy) {
      final turn = Completer<void>();
      _exclusiveWaiters.add(turn);
      await turn.future; // sahipliği devralınmış olarak uyanır (_exclusiveBusy hâlâ true)
    } else {
      _exclusiveBusy = true;
    }
    try {
      return await op();
    } finally {
      if (_exclusiveWaiters.isEmpty) {
        _exclusiveBusy = false;
      } else {
        _exclusiveWaiters.removeAt(0).complete(); // sıradakine devret
      }
    }
  }
  int _flushFailures = 0;

  // --- E-posta ile otomatik fiş aktarımı ---

  InboundAddress? _inbound;
  bool _emailCardDismissed = false;
  bool _emailImportSeen = false;

  /// Son bilinen yönlendirme adresi/durumu (henüz yüklenmediyse null).
  InboundAddress? get inbound => _inbound;

  /// E-posta aktarımı sunulabilir mi: bulut senkronu AÇIK ve sunucuda özellik yapılandırılmış. Senkron kapalıyken hiçbir şey
  /// sunucuya yazılamaz, bu yüzden adım/sihirbaz/kart gösterilmez.
  bool get emailImportAvailable => _syncEnabled && (_inbound?.enabled ?? false);

  /// Ana sayfadaki "Yeni: E-Faturalarını Otomatik Aktar" kartı gösterilsin mi: kapatılmadıysa VE özellik henüz tanıtılmadıysa
  /// (onboarding'in e-posta adımı gösterildiyse ya da sihirbaz/kart açıldıysa kart gereksizdir: o, mevcut kullanıcılar içindir).
  bool get showEmailImportCard => emailImportAvailable && !_emailCardDismissed && !_emailImportSeen;

  /// Ayarlar'daki "Yeni" rozeti: kullanıcı sihirbazı/kartı henüz açmadı.
  bool get emailImportIsNew => emailImportAvailable && !_emailImportSeen;

  /// Yönlendirme adresini sunucudan alır (yoksa üretilir). Senkron kapalıysa ya da hata/çevrimdışıysa son bilinen değer döner
  /// (ağ hatası sessizdir: özellik yalnızca gizli kalır).
  Future<InboundAddress?> loadInbound() async {
    if (user == null) return null;
    if (!_syncEnabled) return _inbound;
    try {
      final info = await api.inboundAddress();
      if (user == null) return _inbound;
      _inbound = info;
      notifyListeners();
    } on ApiException {
      // Çevrimdışı / sunucu hatası: son bilinen değer kalır.
    }
    return _inbound;
  }

  /// Aktarılan fişlerin düşeceği profili seçer (null = en eski/varsayılan profil). Sunucu profil kimliği gerekir; profil henüz
  /// sunucuda değilse (çevrimdışı oluşturuldu) [ApiException] fırlatılır.
  Future<InboundAddress> setInboundProfile(Profile? profile) async {
    if (profile != null && profile.serverId == null) throw ApiException('Profil henüz sunucuda değil; bağlantı gelince tekrar deneyin.');
    final info = await api.setInboundProfile(profile?.serverId);
    _inbound = info;
    notifyListeners();
    return info;
  }

  /// Adresi yeniler (eski adres hemen geçersiz olur).
  Future<InboundAddress> rotateInbound() async {
    final info = await api.rotateInboundAddress();
    _inbound = info;
    notifyListeners();
    return info;
  }

  /// Aktarımı duraklatır / sürdürür; hata [ApiException] olarak yukarı çıkar.
  Future<InboundAddress> setInboundPaused(bool paused) async {
    final info = await api.setInboundPaused(paused);
    _inbound = info;
    notifyListeners();
    return info;
  }

  /// "Son Aktarılan E-Postalar": yalnız özellik kullanılabilirken çekilir; senkron kapalı/çevrimdışı/hata → null (liste
  /// gizlenmez, sihirbaz son bilinen listeyi korur).
  Future<List<InboundHistoryItem>?> loadInboundHistory({int limit = 20}) async {
    if (user == null || !emailImportAvailable) return null;
    try {
      return await api.inboundHistory(limit: limit);
    } on ApiException {
      return null;
    }
  }

  /// Gmail yönlendirme onayını yoklar (sihirbaz açıkken); bekleyen yoksa ya da hata varsa null.
  Future<ForwardingConfirmation?> pollForwardingConfirmation() async {
    if (user == null || !_syncEnabled) return null;
    try {
      return await api.forwardingConfirmation();
    } on ApiException {
      return null;
    }
  }

  /// Ana sayfa kartını kapatır (kalıcı, hesap başına).
  Future<void> dismissEmailImportCard() async {
    final id = user?.id;
    if (id == null) return;
    _emailCardDismissed = true;
    await _write(_emailCardKey(id), '1');
    notifyListeners();
  }

  /// Sihirbaz/kart açıldı: "Yeni" rozeti kaybolur (kalıcı, hesap başına).
  Future<void> markEmailImportSeen() async {
    final id = user?.id;
    if (id == null || _emailImportSeen) return;
    _emailImportSeen = true;
    await _write(_emailSeenKey(id), '1');
    notifyListeners();
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
    _snap.budgets = [for (final b in _snap.budgets) b.state == from ? b.copyWith(state: to) : b];
    await _persistSnapshot();
    notifyListeners();
    if (value) await flushNow(force: true);
  }

  Future<void> _persistSnapshot() async {
    final id = user?.id;
    if (id != null) await _local.save(id, _snap);
  }

  // --- Veri yükleme ---

  Future<void> refresh() => _exclusive(_refreshNow);

  Future<void> _refreshNow() async {
    if (!loggedIn) return;
    final uid = user?.id;
    _needsRefresh = false;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final cats = await api.categories();
      final ps = await api.profiles();
      final ex = await _fetchCloudExpenses();
      // Yanıtlar beklenirken hesap değiştiyse (çıkış / başka hesapla giriş) bu veri yeni hesaba yazılmaz.
      if (user?.id != uid) return;
      categories = cats;
      _snap.categories = cats;
      _applyCloud(ps, ex.list);
      _snap.cloudSyncedAt = ex.syncedAt;
      // Sunucuda artık olmayan fişin çakışmış düzenlemesi çözülemez (gönderilse 404 ile düşerdi): bırakılır.
      final cloudIds = {for (final e in _snap.cloudExpenses) e.id};
      for (final e in _snap.pendingEdits.where((e) => e.isEditConflict && !cloudIds.contains(e.id))) {
        for (final p in e.localImages) {
          await _local.deleteImage(p);
        }
      }
      _snap.pendingEdits = _snap.pendingEdits.where((e) => !e.isEditConflict || cloudIds.contains(e.id)).toList();
      await _refreshBudgets(ps);
      await _persistSnapshot();
      offline = false;
    } on ApiException catch (e) {
      if (e.network) {
        // Bağlantı yok: hata değil, cihazdaki son veriyle çalışma modu (okuma-geçişli önbellek).
        offline = true;
      } else {
        error = e.message;
      }
    } finally {
      // Beklenmeyen bir hata (ör. bozuk JSON) yükleniyor durumunda asılı bırakmasın.
      loading = false;
      notifyListeners();
    }
  }

  /// Artımlı istekte `since`, görülen en yeni `updated_at`ten bu kadar geriden başlar: sunucu `updated_at`'i işlem
  /// içinde atar, uzun bir işlem (500'lük toplu kayıt) daha sonraki zamanlar görünür olduktan SONRA görünür olabilir.
  /// Kimliğe göre üzerine yazıldığından tekrar gelen satırlar zararsızdır.
  static const cloudDeltaOverlap = Duration(minutes: 5);

  /// Sunucu fişleri. Önbellek ve [LocalSnapshot.cloudSyncedAt] varsa ARTIMLI: yalnızca o andan sonra değişenler
  /// (`since`) + tüm kimlikler (silinenler için) çekilir ve önbelleğe işlenir. Yoksa (ilk açılış) ya da artımlı yol
  /// ağ dışı bir hatayla başarısız olursa (eski sunucu, bozuk yanıt...) tam liste çekilir. Ağ hatası olduğu gibi
  /// fırlatılır (tam liste de aynı nedenle başarısız olurdu; çağıran çevrimdışı moda geçer).
  Future<({List<Expense> list, String? syncedAt})> _fetchCloudExpenses() async {
    final since = _snap.cloudSyncedAt;
    final sinceAt = since == null ? null : DateTime.tryParse(since);
    if (sinceAt != null && _snap.cloudExpenses.isNotEmpty) {
      try {
        // Sıra önemli: önce değişenler, sonra kimlikler. Tersinde iki çağrı arasında eklenen fiş delta'da olup
        // kimliklerde olmaz ve silinmiş sanılırdı.
        final changed = await api.expensesSince(sinceAt.subtract(cloudDeltaOverlap).toUtc().toIso8601String());
        final ids = (await api.expenseIds()).toSet();
        final byId = {for (final e in _snap.cloudExpenses) e.id: e};
        for (final e in changed) {
          byId[e.id] = e;
        }
        byId.removeWhere((id, _) => !ids.contains(id));
        return (list: byId.values.toList(), syncedAt: _maxUpdatedAt(changed, since));
      } on ApiException catch (e) {
        if (e.network) rethrow;
      } catch (_) {
        // beklenmeyen yanıt biçimi: tam listeye düş
      }
    }
    final all = await api.expenses();
    return (list: all, syncedAt: _maxUpdatedAt(all, null));
  }

  /// En yeni `updated_at` (ham metin aynen). Metin olarak KARŞILAŞTIRILMAZ: RFC3339Nano sondaki sıfırları atar
  /// (".12Z" > ".123Z" olur); zaman olarak çözülüp karşılaştırılır.
  static String? _maxUpdatedAt(Iterable<Expense> rows, String? prev) {
    var best = prev;
    var bestAt = prev == null ? null : DateTime.tryParse(prev);
    for (final e in rows) {
      final raw = e.updatedAt;
      final at = raw == null ? null : DateTime.tryParse(raw);
      if (at == null) continue;
      if (bestAt == null || at.isAfter(bestAt)) {
        best = raw;
        bestAt = at;
      }
    }
    return best;
  }

  /// Fotoğraf ekleme/silme `updated_at`'i değiştirmez (artımlı yenilemede gelmez): fişin taze kopyası tek tek alınır.
  Future<void> _refreshOne(int id) async {
    try {
      final fresh = await api.expense(id);
      final old = _snap.cloudExpenses.where((e) => e.id == id).firstOrNull;
      var copy = _withProfileUid(fresh);
      if (copy.profileUid.isEmpty && old != null) copy = copy.copyWith(profileUid: old.profileUid);
      _snap.cloudExpenses = [
        for (final e in _snap.cloudExpenses) e.id == id ? copy : e,
        if (old == null) copy,
      ];
      await _persistSnapshot();
    } on ApiException {
      // sonraki tam yenilemede düzelir
    }
  }

  /// Sunucudaki limitler yerel önbelleğe alınır: yüklenmemiş (pending/localOnly) limitler korunur, sunucudan
  /// gelenler eşitlenir. Sunucu bütçe uç noktasını bilmiyorsa (eski sürüm) yerel önbellek olduğu gibi kalır.
  Future<void> _refreshBudgets(List<Profile> serverProfiles) async {
    try {
      final raw = await api.budgets();
      final byServerId = {for (final p in serverProfiles) p.serverId: p.id};
      final server = [
        for (final j in raw) ?Budget.fromServerJson(j, (id) => byServerId[id]),
      ];
      final keep = _snap.budgets.where((b) => b.state != SyncState.synced).toList();
      bool has(Budget b) => keep.any((k) => k.profileUid == b.profileUid && k.categoryId == b.categoryId);
      // Çevrimdışıyken silinmiş (henüz sunucuya bildirilmemiş) limitler geri gelmesin.
      bool deleted(Budget b) => b.serverId != null && _snap.pendingBudgetDeletes.contains(b.serverId);
      _snap.budgets = [...server.where((b) => !has(b) && !deleted(b)), ...keep];
    } on ApiException catch (e) {
      if (e.network) rethrow;
    }
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
    _snap.cloudExpenses = [
      // Artımlı yenilemede önbellekten gelen kopyanın profil eşlemesi korunur (sunucudan gelende profileUid boştur).
      for (final e in serverExpenses) e.copyWith(profileUid: byServerId[e.profileServerId] ?? e.profileUid),
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
    _snap.budgets = _snap.budgets.where((b) => b.profileUid != id).toList();
    _snap.profiles = _snap.profiles.where((x) => x.id != id).toList();
    final goneIds = {for (final e in _snap.cloudExpenses) if (e.profileUid == id) e.id};
    _snap.cloudExpenses = _snap.cloudExpenses.where((e) => e.profileUid != id).toList();
    _snap.pendingEdits = _snap.pendingEdits.where((e) => !goneIds.contains(e.id)).toList();
    _snap.pendingDeletes = _snap.pendingDeletes.where((e) => !goneIds.contains(e)).toList();
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
    // Bütçe eşikleri fişin KENDİ profili için denetlenir (düzenlemede aktif profil değil, fişin profili).
    final profileUid = d.id == null ? activeProfile?.id : (allExpenses.where((e) => e.id == d.id).firstOrNull?.profileUid ?? activeProfile?.id);
    final result = await _saveDraftCore(d);
    if (profileUid != null) {
      try {
        await _checkBudgets(profileUid);
      } catch (_) {
        // Bildirim hatası kaydı etkilemez.
      }
    }
    return result;
  }

  Expense _withProfileUid(Expense e) =>
      e.copyWith(profileUid: _snap.profiles.where((p) => p.serverId == e.profileServerId).firstOrNull?.id ?? '');

  Future<SaveResult> _saveDraftCore(ReceiptDraft d) async {
    final profile = activeProfile;
    if (profile == null) throw ApiException('Önce bir profil seçin.');

    // Cihazdaki (yüklenmemiş) fişi düzenleme.
    if (d.id != null && d.id! < 0) return _updateLocal(d);

    // Sunucudaki fişi düzenleme: yalnızca senkron açıkken.
    if (d.id != null) {
      if (!_syncEnabled) throw ApiException(readOnlyCloudMessage);
      final Expense saved;
      try {
        saved = await api.updateExpense(d.id!, d.toRequestBody());
      } on ApiException catch (e) {
        if (!e.network) rethrow;
        // Bağlantı yok: düzenleme cihaz kuyruğuna alınır, bağlantı gelince PUT ile yüklenir.
        return _queueEdit(d);
      }
      // Liste yenilemesi (refresh) başarısız olsa bile bütçe kontrolü güncel tutarı görsün.
      _snap.cloudExpenses = [for (final x in _snap.cloudExpenses) x.id == saved.id ? _withProfileUid(saved) : x];
      // Bu fişin önceki bekleyen düzenlemesi (varsa) artık geçersiz: sunucu en son hali tuttu.
      _snap.pendingEdits = _snap.pendingEdits.where((x) => x.id != saved.id).toList();
      final ok = await _uploadPending(saved.id, d);
      await refresh();
      return SaveResult(imagesOk: ok);
    }

    // Yeni fiş.
    d.clientUid ??= newClientUid();
    // Mükerrer dijital belge / aynı sipariş reddedilir; resmi fatura, ön özet kaydına birleştirilir (sunucu aynı kuralı uygular;
    // cihaz içi ve çevrimdışı kayıtlar için karar burada, aynı `decideMerge` ile verilir).
    final decision = _digitalDecision(d);
    if (decision.action == kMergeDuplicate) throw _duplicateError(decision);
    // Senkron KAPALIyken bulut kayıtları salt okunurdur (readOnlyCloudMessage): hedef bir bulut ön özetiyse birleştirmek imkânsızdır;
    // resmi fatura yerel kayıt olarak saklanır ve senkron açılınca toplu yüklemede SUNUCU aynı kararla birleştirir (`merged`).
    final cloudTargetReadOnly = !_syncEnabled && decision.target != null && decision.target!.id > 0;
    if (decision.action == kMergeMerge && !cloudTargetReadOnly) {
      return (await _saveMerged(d, decision.target!)).asMerged();
    }
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
    _snap.cloudExpenses = [..._snap.cloudExpenses.where((x) => x.id != saved.id), _withProfileUid(saved)];
    var imagesOk = true;
    var queued = false;
    // Sunucu birleştirdiyse (önbellek bayattı / çevrimdışı kuyruk): hedef kayıt zaten önbellekte güncellendi.
    final mergedByServer = saved.merged;
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
    return SaveResult(imagesOk: imagesOk, queued: queued, merged: mergedByServer);
  }

  // --- Dijital fiş: mükerrer / ön özet + resmi fatura birleştirme (yerel karar) ---

  static String _isoDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  MergeDoc _mergeDocOf(Expense e) => MergeDoc(
    id: e.id,
    merchant: e.merchant,
    amountCents: (e.amount * 100).round(),
    date: _isoDay(e.date),
    documentNo: e.documentNo ?? '',
    orderId: e.orderId ?? '',
    items: [for (final i in e.items) i.name],
  );

  /// Taslağın `document_no`/`order_id`'sine göre kayıt / mükerrer / birleştirme kararı (Go `DecideMerge` ikizi). Hesaptaki tüm
  /// fişler (cihaz kuyruğu + bulut önbelleği, tüm profiller) aday olur; taslağın kendisi hariçtir.
  ({String action, Expense? target, bool byDocument}) _digitalDecision(ReceiptDraft d) {
    if (d.documentNo == null && d.orderId == null) return (action: kMergeCreate, target: null, byDocument: false);
    final pool = [for (final e in allExpenses) if (d.clientUid == null || e.clientUid != d.clientUid) e];
    final incoming = MergeDoc(
      merchant: d.merchant,
      amountCents: (d.savedAmount * 100).round(),
      date: _isoDay(d.date),
      documentNo: d.documentNo ?? '',
      orderId: d.orderId ?? '',
      items: [for (final i in d.items) i.name],
    );
    final dec = decideMerge(incoming, [for (final e in pool) _mergeDocOf(e)]);
    final target = dec.action == kMergeCreate ? null : pool.where((e) => e.id == dec.targetId).firstOrNull;
    if (target == null) return (action: kMergeCreate, target: null, byDocument: false);
    return (action: dec.action, target: target, byDocument: d.documentNo != null && target.documentNo == d.documentNo);
  }

  ApiException _duplicateError(({String action, Expense? target, bool byDocument}) dec) => dec.byDocument
      ? ApiException('Bu dijital fatura zaten eklenmiş.', status: 409, code: 'duplicate_document')
      : ApiException('Bu sipariş zaten eklenmiş.', status: 409, code: 'duplicate_order');

  /// Resmi faturayı [target] ön özet kaydına işler: kullanıcının alanları (işletme, tarih, kategori, not, mevcut kalemler)
  /// korunur; `document_no` (kayıt kilitlenir), boşsa `order_id`, kesin toplam ve — hedefte kalem yoksa — kalemler yazılır.
  /// Kayıt mevcut düzenleme yoluyla gider (bulut: PUT, çevrimdışı: bekleyen düzenleme, cihaz: yerel güncelleme).
  Future<SaveResult> _saveMerged(ReceiptDraft d, Expense target) {
    final md = ReceiptDraft.from(target);
    if (target.items.isEmpty) {
      md.items = [for (final i in d.items) i];
      md.discount = d.discount;
    }
    final want = d.savedAmount;
    final gap = ((want - md.savedAmount) * 100).round() / 100;
    if (gap > 0.005) {
      // KDV'siz kalem toplamı: fark ayrı "KDV" kalemi (kaydedilen tutar resmi toplam olsun).
      md.items.add(ExpenseItem('KDV', gap, categoryId: md.categoryId, categoryName: _categoryName(md.categoryId) ?? kOtherCategory));
    } else if (gap < -0.005) {
      md.discount = ((md.discount + (-gap)) * 100).round() / 100;
    }
    md.documentNo = d.documentNo;
    md.orderId ??= d.orderId;
    md.ocrEngine ??= d.ocrEngine;
    md.pendingImages = d.pendingImages;
    return _saveDraftCore(md);
  }

  // --- Bütçe limitleri ---

  /// Aktif profilin kategori limitleri.
  List<Budget> get budgets => List.unmodifiable(_snap.budgets.where((b) => b.profileUid == activeProfileId));

  /// Aktif profilin bu ayki limit / harcama ilerlemesi (kategori adına göre sıralı).
  List<BudgetProgress> get budgetProgress =>
      computeBudgetProgress(_activeUnsorted(), _snap.budgets, activeProfileId ?? '', _clock());

  Budget? _budgetOf(String profileUid, int categoryId) =>
      _snap.budgets.where((b) => b.profileUid == profileUid && b.categoryId == categoryId).firstOrNull;

  /// Aktif profil için kategori limitini koyar/günceller. Senkron açık + çevrimiçiyse sunucuya; bağlantı yoksa
  /// (ya da profil henüz sunucuda değilse) cihaz kuyruğuna ([SyncState.pending]); senkron kapalıysa yalnızca
  /// cihaza ([SyncState.localOnly]). Senkron kapalıyken bulutta kayıtlı limit değiştirilemez.
  Future<void> setBudget(int categoryId, double limit) async {
    final p = activeProfile;
    if (p == null || limit <= 0) return;
    final name = categoryId == kTotalBudgetCategoryId ? kTotalBudgetName : (_categoryName(categoryId) ?? '');
    final existing = _budgetOf(p.id, categoryId);
    Budget make(SyncState state, {int? serverId, double? lim}) => Budget(
      profileUid: p.id,
      categoryId: categoryId,
      categoryName: name,
      limit: lim ?? limit,
      serverId: serverId,
      state: state,
    );
    Budget next;
    if (_syncEnabled && p.serverId != null) {
      try {
        final j = await api.putBudget(p.serverId!, categoryId, limit);
        next = make(
          SyncState.synced,
          serverId: (j['id'] as num?)?.toInt(),
          lim: (j['monthly_limit'] as num?)?.toDouble(),
        );
      } on ApiException catch (e) {
        if (!e.network) rethrow;
        next = make(SyncState.pending, serverId: existing?.serverId);
      }
    } else if (_syncEnabled) {
      next = make(SyncState.pending, serverId: existing?.serverId);
    } else {
      if (existing != null && existing.state == SyncState.synced) throw ApiException(readOnlyCloudMessage);
      next = make(SyncState.localOnly);
    }
    _snap.budgets = [
      ..._snap.budgets.where((b) => !(b.profileUid == p.id && b.categoryId == categoryId)),
      next,
    ];
    await _persistSnapshot();
    notifyListeners();
  }

  /// Aktif profildeki kategori limitini kaldırır.
  Future<void> removeBudget(int categoryId) async {
    final p = activeProfile;
    final existing = p == null ? null : _budgetOf(p.id, categoryId);
    if (existing == null) return;
    if (existing.serverId != null) {
      if (!_syncEnabled) throw ApiException(readOnlyCloudMessage);
      try {
        await api.deleteBudget(existing.serverId!);
      } on ApiException catch (e) {
        if (e.network) {
          // Bağlantı yok: silme kuyruğa alınır (yerelde hemen kalkar), bağlantı gelince sunucuya bildirilir.
          if (!_snap.pendingBudgetDeletes.contains(existing.serverId)) {
            _snap.pendingBudgetDeletes = [..._snap.pendingBudgetDeletes, existing.serverId!];
          }
        } else if (e.status != 404) {
          rethrow; // 404: sunucuda zaten yok
        }
      }
    }
    _snap.budgets = _snap.budgets.where((b) => !(b.profileUid == existing.profileUid && b.categoryId == categoryId)).toList();
    await _persistSnapshot();
    notifyListeners();
  }

  bool _permissionAsked = false;

  /// Fiş kaydedildi/güncellendi: [profileUid] profilinin içinde bulunulan aydaki bütçe eşiklerini (%80 / %100)
  /// denetler; bir eşik o ay ilk kez aşılmışsa yerel bildirim gönderir (aynı ay + aynı eşik için tekrar yok).
  Future<void> _checkBudgets(String profileUid) async {
    final id = user?.id;
    if (id == null) return;
    final now = _clock();
    final progress = computeBudgetProgress(allExpenses, _snap.budgets, profileUid, now);
    final r = evaluateBudgetAlerts(progress, _alertsSent, now);
    _alertsSent = r.sent;
    if (r.alerts.isEmpty) return;
    await _write(_alertsKey(id), jsonEncode(_alertsSent.toList()));
    if (!_permissionAsked) {
      _permissionAsked = true;
      await notifier.requestPermission();
    }
    for (final a in r.alerts) {
      final b = a.progress.budget;
      await notifier.show(
        id: budgetNotificationId(b.profileUid, b.categoryId, a.threshold),
        title: a.title,
        body: a.body,
        payload: 'budgets',
      );
    }
  }

  // --- Tekrarlayan giderler ---

  /// Aktif profilin tekrarlayan giderleri ve "Aylık Sabit Gider Projeksiyonu".
  // buildRecurring tüm fişleri tarar (regex'li seri anahtarı): her notify'da, her satırda yeniden hesaplanmasın diye
  // veri sürümüne (her notifyListeners'ta artar) ve güne bağlı önbelleklenir.
  int _rev = 0;
  RecurringProjection? _recurringCache;
  int _recurringCacheRev = -1;
  String _recurringCacheDay = '';

  RecurringProjection get recurring {
    final day = _todayKey();
    if (_recurringCache == null || _recurringCacheRev != _rev || _recurringCacheDay != day) {
      _recurringCache = buildRecurring(_activeUnsorted(), _clock());
      _recurringCacheRev = _rev;
      _recurringCacheDay = day;
    }
    return _recurringCache!;
  }

  /// Önümüzdeki 30 gün içinde ödemesi gelen tekrarlayan giderler (aktif profil).
  List<RecurringItem> get upcomingPayments => upcomingPaymentsOf(recurring.items, _clock());

  // --- Türetilen çıktılar: ana ekran widget'ı ve ödeme hatırlatıcıları ---

  bool _derivedQueued = false;
  bool _disposed = false;
  WidgetPayload? _lastWidget;
  bool _widgetPushed = false;
  String? _lastWidgetTheme;

  /// Tema adı + (yalnızca marka temasında) marka rengi; değişmedikçe yeniden yazılmaz.
  void _pushWidgetTheme() {
    if (_disposed) return;
    final t = themeController.widgetTheme;
    final accent = themeController.logoColor.toARGB32();
    final sig = t == WidgetTheme.brand ? '${t.name}:$accent' : t.name;
    if (sig == _lastWidgetTheme) return;
    _lastWidgetTheme = sig;
    unawaited(_widget.updateTheme(t.name, accent));
  }
  String? _lastReminderSig;
  Future<void> _derivedChain = Future.value();

  @override
  void notifyListeners() {
    _rev++;
    super.notifyListeners();
    // Fiş ekleme/silme/güncelleme, profil değişimi, yenileme, senkron/çıkış... hepsi buradan geçer; widget ve
    // hatırlatıcılar değişiklik olduğunda (aynı veri tekrar gönderilmez) güncellenir.
    if (_derivedQueued || _disposed) return;
    _derivedQueued = true;
    scheduleMicrotask(() {
      _derivedQueued = false;
      if (!_disposed) _syncDerived();
    });
  }

  WidgetPayload? _widgetPayload() {
    if (user == null) return null;
    final now = _clock();
    return WidgetPayload(
      profileName: activeProfile?.name ?? '',
      monthTotalText: fmtMoney(monthTotalFor(_activeUnsorted(), activeProfileId, now)),
      monthLabel: '${kMonthNames[now.month - 1]} ${now.year}',
      monthKey: '${now.year}-${now.month}',
    );
  }

  void _syncDerived() {
    final payload = _widgetPayload();
    if (payload != null ? payload != _lastWidget : _widgetPushed) {
      _lastWidget = payload;
      _widgetPushed = payload != null;
      unawaited(_widget.update(payload));
    }

    // Ödeme hatırlatıcıları: tüm profillerin tekrarlayan giderleri için bir sonraki ödemeye göre.
    final now = _clock();
    final plans = user == null || !allExpenses.any((e) => e.isRecurring)
        ? const <ReminderPlan>[]
        : planReminders(buildRecurring(allExpenses, now).items, now);
    final sig = plans.map((p) => '${p.id}@${p.when.millisecondsSinceEpoch}').join(',');
    if (sig == (_lastReminderSig ?? '')) return;
    _lastReminderSig = sig;
    _derivedChain = _derivedChain.then((_) async {
      await notifier.cancelScheduled();
      for (final p in plans) {
        await notifier.schedule(id: p.id, when: p.when, title: p.title, body: p.body, payload: 'recurring');
      }
    });
  }

  /// Çıkış / hesap silme: widget verisi, planlı ve gösterilmiş bildirimler temizlenir.
  Future<void> _clearDerivedOutputs() async {
    _lastReminderSig = '';
    if (_widgetPushed || _lastWidget != null) {
      _lastWidget = null;
      _widgetPushed = false;
      await _widget.update(null);
    }
    await _derivedChain;
    await notifier.cancelAll();
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
      categoryName: _categoryName(cid) ?? kOtherCategory,
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
      recurringDay: d.recurringDay,
      recurringRemind: d.recurringRemind,
      // Çevrimdışı kuyruktaki değişken fatura (elektrik, su...) sunucuya "sabit" olarak gitmesin.
      recurringKind: d.recurringKind,
      recurringEstimate: d.recurringEstimate,
      ocrEngine: d.ocrEngine,
      documentNo: d.documentNo,
      orderId: d.orderId,
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

  /// Sunucudaki bir fişin çevrimdışı düzenlemesi: görünümde hemen yansır ([SyncState.pending]), bağlantı gelince
  /// `PUT /expenses/:id` ile yüklenir (bkz. [SyncService]). Aynı fişin önceki bekleyen düzenlemesinin yerini alır.
  Future<SaveResult> _queueEdit(ReceiptDraft d) async {
    final id = d.id!;
    final prior = _snap.pendingEdits.where((e) => e.id == id).firstOrNull;
    final orig = prior ?? _snap.cloudExpenses.where((e) => e.id == id).firstOrNull;
    if (orig == null) throw ApiException('Fiş bulunamadı.');
    final extra = await _storeImages(d.pendingImages);
    _zero(d);
    d.clientUid = orig.clientUid;
    final edited = _fromDraft(
      d,
      id: id,
      profile: _profile(orig.profileUid) ?? activeProfile!,
      state: SyncState.pending,
      images: [...?prior?.localImages, ...extra],
      // Düzenlemenin dayandığı sunucu sürümü kuyruğa alınırken sabitlenir (gönderimde değil): arada yapılan bir
      // yenileme önbelleği başka cihazın yeni sürümüyle güncellese de PUT o değişikliği sessizce ezmez (409).
    ).copyWith(imageIds: orig.imageIds, profileServerId: orig.profileServerId, updatedAt: orig.updatedAt);
    _snap.pendingEdits = [..._snap.pendingEdits.where((e) => e.id != id), edited];
    await _persistSnapshot();
    notifyListeners();
    return const SaveResult(queued: true);
  }

  /// Aktif profilde [merchant] + [categoryId] ile eşleşen AKTİF tekrarlayan seri (yoksa null). Yeni fiş formu,
  /// aynı kurumun yeni ay faturasını girerken "Her ay tekrarlanır"ı (gün, tür, tahmin) otomatik önerir; böylece
  /// fiş seriyi sürdürür ve o ayın kalemi otomatik "ödendi" olur.
  ///
  /// Önce birebir seri anahtarı; yoksa ve [amount] verildiyse BULANIK eşleşme (OCR işletme adını farklı okuyunca yeni
  /// ay faturası seriye bağlansın): işletme adı jetonları alt küme + o ay ödenmemiş + tutar ±%30 ([seriesMatchFor]).
  RecurringItem? seriesFor(String merchant, int? categoryId, {double? amount}) =>
      seriesMatchFor(recurring.items, merchant, categoryId, amount: amount);

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
    try {
      await api.deleteExpense(id);
    } on ApiException catch (e) {
      if (!e.network) rethrow;
      // Bağlantı yok: silme cihaz kuyruğuna alınır (liste hemen güncellenir), bağlantı gelince yüklenir.
      _snap.pendingEdits = _snap.pendingEdits.where((x) => x.id != id).toList();
      if (!_snap.pendingDeletes.contains(id)) _snap.pendingDeletes = [..._snap.pendingDeletes, id];
      await _persistSnapshot();
      notifyListeners();
      return;
    }
    // Silinen fişin (ör. çakışmış) bekleyen düzenlemesi de anlamını yitirdi.
    _snap.pendingEdits = _snap.pendingEdits.where((x) => x.id != id).toList();
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
    await _refreshOne(e.id);
    await refresh();
  }

  Future<void> removeCloudImage(int expenseId, int imageId) async {
    if (!_syncEnabled) throw ApiException(readOnlyCloudMessage);
    await api.deleteImage(expenseId, imageId);
    await _refreshOne(expenseId);
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
    final byName = _snap.profiles.where((p) => foldTR(p.name) == foldTR(name.trim())).firstOrNull;
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

  int? _otherCategoryId() => categories.where((c) => c.name == kOtherCategory).firstOrNull?.id;

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
    if (await _preferOnDeviceOcr()) return _refineOnDeviceWithServer(await _onDeviceOcr.scan(pages));
    final ocrEngine = ocrFactory.resolve(api, engineName: engine);
    try {
      return await ocrEngine.scan(pages);
    } on ApiException catch (e) {
      if (!e.network) rethrow;
      return _onDeviceOcr.scan(pages);
    }
  }

  /// Kısmi taramada (bazı sayfalar okunamadı) YALNIZ okunamayan sayfaları yeniden tarar, metinleri sayfa sırasıyla
  /// birleştirip yeniden ayrıştırır. [pages] ilk taramadaki tam sayfa listesidir (sırası aynı).
  Future<ScanResult> rescanFailedPages(ScanResult prev, List<Uint8List> pages, {String? engine}) async {
    final failed = prev.ocr.failedPages;
    final texts = prev.ocr.pageTexts;
    if (failed.isEmpty || texts.length != pages.length) return prev;
    final idx = [for (final n in failed) if (n >= 1 && n <= pages.length) n - 1];
    final sub = await scanAndParseReceipt([for (final i in idx) pages[i]], engine: engine);
    final merged = List<String>.of(texts);
    final stillFailed = <int>[];
    for (var k = 0; k < idx.length; k++) {
      final subTexts = sub.ocr.pageTexts;
      final text = k < subTexts.length ? subTexts[k] : '';
      if (sub.ocr.failedPages.contains(k + 1) || (text.trim().isEmpty && subTexts.isNotEmpty)) {
        stillFailed.add(idx[k] + 1);
      } else if (k < subTexts.length) {
        merged[idx[k]] = text;
      }
    }
    final raw = mergePageTexts(merged.where((t) => t.trim().isNotEmpty).toList());
    // Karışık motor (ör. ilk tarama sunucu, yeniden tarama cihaz): fişte ilk taramanın motoru korunur.
    final ocr = sub.ocr.copyWith(rawText: raw, pageTexts: merged, failedPages: stillFailed, engine: prev.ocr.engine);
    ParsedReceipt parsed;
    try {
      parsed = await api.parseReceiptText(raw);
    } catch (_) {
      parsed = parseReceiptText(raw, now: DateTime.now()).toParsedReceipt(otherCategoryId: _otherCategoryId());
    }
    if (stillFailed.isNotEmpty) parsed = parsed.copyWith(needsReview: true);
    return (ocr: ocr, parsed: parsed);
  }

  /// Cihazda okunan metin için sunucu ayrıştırıcısını kullanır (kategori kuralları, toplam mutabakatı, marka
  /// sözlüğü): YALNIZCA bulut senkronu açık ve çevrimiçiyken ve yalnızca metin gider (fotoğraf asla). Senkron
  /// kapalı/çevrimdışıysa ya da çağrı başarısızsa yerel ayrıştırma sonucu aynen kalır; hiçbir istek atılmaz.
  Future<ScanResult> _refineOnDeviceWithServer(ScanResult local) async {
    final text = local.ocr.rawText;
    if (!_syncEnabled || text.trim().isEmpty || utf8.encode(text).length > 20000) return local;
    try {
      if (!await _connectivity.isOnline()) return local;
      final parsed = await api.parseReceiptText(text);
      return (ocr: local.ocr, parsed: parsed);
    } catch (_) {
      return local;
    }
  }

  // --- Dijital fiş / e-fatura (PDF) ---

  /// Hesapta (cihaz kuyruğu + bulut önbelleği, tüm profiller) bu dijital fatura kimliğiyle kayıtlı fiş; yoksa null.
  Expense? expenseWithDocument(String documentNo) {
    for (final e in allExpenses) {
      if (e.documentNo == documentNo) return e;
    }
    return null;
  }

  /// PDF dosyasını (cihazdan seçilen ya da "Paylaş → Fissio" ile gelen) okuyup fiş taslağına çevirir.
  ///
  /// Metin katmanlı PDF (e-fatura, e-arşiv, uygulama fişi): metin cihazda çıkarılır, OCR kullanılmaz (`ocrEngine` =
  /// `pdf`). Taranmış (görsel) PDF: sayfalar görsele çevrilip mevcut OCR hattına düşer (mod/senkron kuralları aynen).
  /// Senkron AÇIK ve çevrimiçiyken yalnızca METİN sunucu ayrıştırıcısına gider (kategori kuralları); aksi halde hiçbir
  /// istek atılmaz. Belge kimliği (ETTN / VKN_FaturaNo) bulunursa ve hesapta zaten ekliyse [ApiException] (409,
  /// `duplicate_document`) fırlatılır.
  Future<ReceiptDraft> readDigitalReceipt(String path) async {
    final lower = path.toLowerCase();
    if (lower.endsWith('.eml')) return _readEmlFile(path);
    if (lower.endsWith('.html') || lower.endsWith('.htm')) return _readHtmlFile(path);
    return _readPdfFile(path);
  }

  /// `.eml` (paylaşılan / dosyadan seçilen e-posta): öncelik (1) PDF eki (ya da zip içindeki PDF) — metin katmanı, taranmışsa
  /// mevcut OCR yedeği; (2) PDF yoksa (ya da okunamıyorsa) HTML gövde temizlenip metin ayrıştırıcıya; (3) düz metin gövde.
  Future<ReceiptDraft> _readEmlFile(String path) async {
    final EmlMessage msg;
    try {
      msg = parseEml(await _readFileBytes(path));
    } on EmlException {
      throw ApiException('E-posta dosyası okunamadı.');
    }
    ApiException? pdfError;
    for (final a in msg.pdfs) {
      final tmp = await _writeTempPdf(a.bytes);
      try {
        return await _readPdfFile(tmp);
      } on ApiException catch (e) {
        if (e.duplicateDocument || e.duplicateOrder || e.network) rethrow;
        pdfError = e; // PDF okunamadı: gövdeye düş
      } finally {
        try {
          await File(tmp).delete();
        } catch (_) {}
      }
    }
    final body = msg.html.trim().isNotEmpty ? htmlToText(msg.html) : msg.text;
    final text = stripForwardPreamble(body);
    if (text.trim().isEmpty) throw pdfError ?? ApiException('E-postada okunabilir fiş metni bulunamadı.');
    return _draftFromDigitalText(text, engine: kStoredEmail, subject: msg.subject, from: msg.from);
  }

  /// `.html` dosyası (ya da paylaşılan HTML sipariş özeti): temizlenip metin ayrıştırıcıya gider.
  Future<ReceiptDraft> _readHtmlFile(String path) async {
    final raw = await _readFileBytes(path);
    final text = stripForwardPreamble(htmlToText(utf8.decode(raw, allowMalformed: true)));
    if (text.trim().isEmpty) throw ApiException('HTML içinde okunabilir fiş metni bulunamadı.');
    return _draftFromDigitalText(text, engine: kStoredEmail);
  }

  Future<Uint8List> _readFileBytes(String path) async {
    final f = File(path);
    try {
      if (await f.length() > 30 * 1024 * 1024) throw ApiException('Dosya çok büyük (en çok 30 MB).');
      return await f.readAsBytes();
    } on FileSystemException {
      throw ApiException('Dosya okunamadı.');
    }
  }

  Future<String> _writeTempPdf(Uint8List bytes) async {
    final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}fissio_eml_${DateTime.now().microsecondsSinceEpoch}.pdf');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  /// Metinden (PDF katmanı / HTML / düz metin) taslak: belge kimliği + sipariş kodu çıkarılır, mükerrer ise [ApiException]
  /// fırlatılır (ön özet + resmi fatura birleştirmesi kayıtta yapılır: [saveDraft]).
  Future<ReceiptDraft> _draftFromDigitalText(String text, {required String engine, String? subject, String? from}) async {
    final documentNo = extractDocumentNo(text);
    final orderId = extractOrderId(text);
    final local = parseReceiptText(text, now: _clock()).toParsedReceipt(otherCategoryId: _otherCategoryId());
    final parsed = (await _refineTextWithServer(text, local)) ?? local;
    if (parsed.needsManual) {
      throw ApiException('Metinden tutar okunamadı. Bilgileri elle girebilirsiniz.');
    }
    final draft = _withVatLine(ReceiptDraft.fromParsed(parsed), parsed)
      ..ocrEngine = engine
      ..documentNo = documentNo
      ..orderId = orderId;
    if (draft.merchant.trim().isEmpty && from != null) {
      final m = RegExp(r'^\s*"?([^"<]+?)"?\s*<').firstMatch(from);
      if (m != null) draft.merchant = m[1]!.trim();
    }
    if (draft.note.isEmpty && subject != null && subject.trim().isNotEmpty) {
      final n = 'E-posta: ${subject.trim()}';
      draft.note = n.length > 200 ? n.substring(0, 200) : n;
    }
    final decision = _digitalDecision(draft);
    if (decision.action == kMergeDuplicate) throw _duplicateError(decision);
    return draft;
  }

  Future<ReceiptDraft> _readPdfFile(String path) async {
    final List<String> pageTexts;
    try {
      pageTexts = await pdfReader.readText(path);
    } on PdfReadException catch (e) {
      throw ApiException(e.message);
    }
    if (!hasUsableTextLayer(pageTexts)) return _readScannedPdf(path);

    final text = joinPageTexts(pageTexts);
    final documentNo = extractDocumentNo(text);
    final orderId = extractOrderId(text);
    final local = parseReceiptText(text, now: _clock()).toParsedReceipt(otherCategoryId: _otherCategoryId());
    final parsed = (await _refineTextWithServer(text, local)) ?? local;
    if (parsed.needsManual) {
      throw ApiException('PDF içinden tutar okunamadı. Bilgileri elle girebilirsiniz.');
    }
    final draft = _withVatLine(ReceiptDraft.fromParsed(parsed), parsed)
      ..ocrEngine = kStoredPdf
      ..documentNo = documentNo
      ..orderId = orderId;
    _rejectDuplicateDraft(draft);
    return draft;
  }

  /// E-fatura / e-arşiv kalem tutarları KDV'sizdir ("Mal Hizmet Tutarı" + KDV = "Ödenecek Tutar"); ayrıştırıcı bunu
  /// uyuşmazlık saymaz (`items_exclude_vat`). Ama kaydedilen tutar kalem toplamıdır: fark ayrı bir "KDV" kalemi olarak
  /// eklenmezse fatura KDV kadar eksik kaydedilirdi. İndirimli ya da uyuşmazlık bayraklı belgelere dokunulmaz.
  ReceiptDraft _withVatLine(ReceiptDraft d, ParsedReceipt p) {
    final total = p.amount;
    if (total == null || p.needsReview || p.discountTotal > 0 || p.items.isEmpty) return d;
    final gap = ((total - d.itemsTotal) * 100).round() / 100;
    if (gap > 0.005) {
      d.items.add(ExpenseItem('KDV', gap, categoryId: d.categoryId, categoryName: p.categoryName, categoryReview: p.categoryNeedsReview));
    }
    return d;
  }

  Future<ReceiptDraft> _readScannedPdf(String path) async {
    final List<Uint8List> pages;
    try {
      pages = await pdfReader.renderPages(path);
    } on PdfReadException catch (e) {
      throw ApiException(e.message);
    }
    final res = await scanAndParseReceipt(pages, engine: themeController.ocrEngine);
    if (res.ocr.isEmpty || res.parsed.needsManual) {
      throw ApiException('PDF okunamadı. Bilgileri elle girebilirsiniz.');
    }
    final draft = _withVatLine(ReceiptDraft.fromParsed(res.parsed), res.parsed)
      ..pendingImages = pages
      ..ocrEngine = storedOcrEngineId(res.ocr.engine)
      ..documentNo = extractDocumentNo(res.ocr.rawText)
      ..orderId = extractOrderId(res.ocr.rawText);
    _rejectDuplicateDraft(draft);
    return draft;
  }

  /// Aynı belge / aynı sipariş (+aynı tür) zaten kayıtlıysa [ApiException] (409). Ön özete birleşecek resmi fatura reddedilmez.
  void _rejectDuplicateDraft(ReceiptDraft d) {
    final decision = _digitalDecision(d);
    if (decision.action == kMergeDuplicate) throw _duplicateError(decision);
  }

  /// Cihazda okunan metin için sunucu ayrıştırıcısı ([_refineOnDeviceWithServer] ile aynı kurallar): YALNIZCA senkron
  /// açık ve çevrimiçiyken ve yalnızca metin gider; aksi halde ya da hatada null (yerel sonuç kalır).
  Future<ParsedReceipt?> _refineTextWithServer(String text, ParsedReceipt local) async {
    if (!_syncEnabled || text.trim().isEmpty || utf8.encode(text).length > 20000) return null;
    try {
      if (!await _connectivity.isOnline()) return null;
      return await api.parseReceiptText(text);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    themeController.removeListener(_pushWidgetTheme);
    _stopBackground();
    super.dispose();
  }
}

extension on String {
  String? get nonEmpty => isEmpty ? null : this;
}

final appState = AppState();
