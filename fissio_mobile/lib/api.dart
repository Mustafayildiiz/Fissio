import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'device_info.dart';
import 'models.dart';
import 'ocr/ocr_engine.dart';

class ApiException implements Exception {
  final String message;
  final int? status;
  final bool network;

  /// Sunucunun makine okunur hata kodu (`invalid_code`, `code_expired`, `email_not_verified` ...).
  final String? code;

  /// `resend_cooldown` için yeniden deneme süresi (saniye).
  final int? retryAfter;

  /// `PUT /expenses/:id` 409 `conflict`: sunucudaki güncel fiş (başka cihazda değişmiş).
  final Expense? current;
  ApiException(
    this.message, {
    this.status,
    this.network = false,
    this.code,
    this.retryAfter,
    this.current,
  });

  /// Düzenleme, dayandığı sürümden (`base_updated_at`) sonra sunucuda değişmiş bir fişe yapıldı; yazılmadı.
  bool get conflict => status == 409 && code == 'conflict';

  /// Aynı dijital fatura (ETTN / VKN_FaturaNo) hesapta zaten ekli (`POST|PUT /expenses` 409).
  bool get duplicateDocument => status == 409 && code == 'duplicate_document';
  @override
  String toString() => message;
}

/// Yayın: tek origin (ters vekil/Caddy, bkz. Caddyfile): `--dart-define=API_BASE=https://api.ornek.com`. Verilirse auth ve expense
/// aynı tabanı kullanır (`/auth/*` auth'a, gerisi expense'e yönlenir) ve API_HOST/8081/8082 yok sayılır.
const _apiBase = String.fromEnvironment('API_BASE');

/// Gerçek cihazda: `flutter run --dart-define=API_HOST=192.168.x.x`.
/// Tanımlı değilse Android emülatöründe host makine 10.0.2.2, diğerlerinde localhost.
const _hostOverride = String.fromEnvironment('API_HOST');
String get _host {
  if (_hostOverride.isNotEmpty) return _hostOverride;
  return (!kIsWeb && Platform.isAndroid) ? '10.0.2.2' : 'localhost';
}

/// Kısa ömürlü access token + tek kullanımlık (rotasyonlu) refresh token.
class AuthTokens {
  final String access;
  final String refresh;
  final DateTime expiresAt;
  const AuthTokens({
    required this.access,
    required this.refresh,
    required this.expiresAt,
  });

  factory AuthTokens.fromJson(Map<String, dynamic> j) => AuthTokens(
    access: j['access_token'] as String,
    refresh: j['refresh_token'] as String,
    expiresAt: DateTime.parse(j['expires_at'] as String),
  );
}

class AuthSession {
  final AuthTokens tokens;
  final AuthUser user;
  const AuthSession(this.tokens, this.user);
}

/// Açık oturum (cihaz) — Ayarlar > Aktif oturumlar.
class DeviceSession {
  final String id;
  final String deviceName;
  final String platform;
  final DateTime lastActiveAt;
  final DateTime createdAt;
  final bool current;
  const DeviceSession({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.lastActiveAt,
    required this.createdAt,
    required this.current,
  });
  factory DeviceSession.fromJson(Map<String, dynamic> j) => DeviceSession(
    id: j['id'] as String,
    deviceName: (j['device_name'] as String?) ?? '',
    platform: (j['platform'] as String?) ?? '',
    lastActiveAt: DateTime.parse(j['last_active_at'] as String),
    createdAt: DateTime.parse(j['created_at'] as String),
    current: (j['current'] as bool?) ?? false,
  );
}

/// `POST /expenses/bulk` yanıtı: fiş başına sonuç (created | skipped | error).
class BulkItemResult {
  final int index;
  final String clientUid;
  final String status;
  final int? id;
  final String? error;
  const BulkItemResult(this.index, this.clientUid, this.status, this.id, this.error);
  bool get ok => status == 'created' || status == 'skipped';
}

class BulkResponse {
  final int created;
  final int skipped;
  final int failed;
  final List<BulkItemResult> results;
  const BulkResponse(this.created, this.skipped, this.failed, this.results);
}

class ApiClient {
  ApiClient({
    http.Client? client,
    this.onUnauthorized,
    this.onTokensChanged,
    this.onSuccess,
    DeviceInfoProvider? device,
    DateTime Function()? clock,
    String? authBase,
    String? expenseBase,
  }) : _client = client ?? http.Client(),
       _device = device ?? PluginDeviceInfo(),
       _clock = clock ?? DateTime.now,
       _auth = authBase ?? (_apiBase.isNotEmpty ? _apiBase : 'http://$_host:8081'),
       _expense = expenseBase ?? (_apiBase.isNotEmpty ? _apiBase : 'http://$_host:8082');

  final http.Client _client;
  final DeviceInfoProvider _device;
  final DateTime Function() _clock;

  /// Refresh de başarısız olunca (oturum gerçekten bitti) çağrılır.
  void Function()? onUnauthorized;

  /// Token çifti değişince (giriş, yenileme, çıkış) çağrılır; AppState güvenli depoya yazar.
  void Function(AuthTokens? tokens)? onTokensChanged;

  /// Her başarılı (2xx) istekten sonra çağrılır (çevrimdışı kuyruğu boşaltmayı tetiklemek için).
  void Function()? onSuccess;

  final String _auth;
  final String _expense;

  AuthTokens? _tokens;
  Future<bool>? _refreshing;

  AuthTokens? get tokens => _tokens;
  String? get token => _tokens?.access;

  /// Oturum açıkken değiştirilen token'ları AppState geri yükler/temizler.
  void setTokens(AuthTokens? t, {bool notify = true}) {
    _tokens = t;
    if (notify) onTokensChanged?.call(t);
  }

  // --- İstek altyapısı ---

  http.Request _jsonReq(String method, Uri uri, Map<String, dynamic>? body, bool authed) {
    final req = http.Request(method, uri)..headers['Content-Type'] = 'application/json';
    final t = _tokens?.access;
    if (authed && t != null) req.headers['Authorization'] = 'Bearer $t';
    if (body != null) req.body = jsonEncode(body);
    return req;
  }

  Future<dynamic> _send(
    String method,
    String base,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool authed = true,
  }) {
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    return _dispatch(() => _jsonReq(method, uri, body, authed), authed: authed);
  }

  Future<http.Response> _sendOnce(http.BaseRequest req, Duration timeout) async {
    try {
      return await http.Response.fromStream(await _client.send(req).timeout(timeout));
    } catch (_) {
      throw ApiException(
        'Sunucuya ulaşılamıyor. İnternet bağlantınızı kontrol edin.',
        network: true,
      );
    }
  }

  /// İsteği gönderir. Access token süresi dolmaya yakınsa önce yeniler; 401 gelirse refresh token ile
  /// sessizce yenileyip isteği BİR kez tekrarlar (kullanıcı oturumdan düşmez). Refresh de reddedilirse
  /// oturum biter ([onUnauthorized]); ağ hatasında oturum KORUNUR. [build] her denemede yeniden çağrılır
  /// (multipart istekler tek kullanımlıktır).
  Future<dynamic> _dispatch(
    http.BaseRequest Function() build, {
    bool authed = true,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (authed && _tokens != null) await _refreshIfExpiring();
    var used = _tokens?.access;
    var r = await _sendOnce(build(), timeout);

    if (r.statusCode == 401 && authed && used != null) {
      final code = _errorBody(r)?['code'];
      if (code == 'session_revoked') {
        _expire();
      } else {
        // Başka bir istek token'ı zaten yenilediyse yeniden yenilemeye gerek yok.
        final alreadyRotated = _tokens != null && _tokens!.access != used;
        if (alreadyRotated || await _refresh()) {
          used = _tokens?.access;
          r = await _sendOnce(build(), timeout);
        }
        if (r.statusCode == 401) _expire();
      }
    }

    if (r.statusCode >= 200 && r.statusCode < 300) {
      onSuccess?.call();
      if (r.body.isEmpty) return null;
      return jsonDecode(utf8.decode(r.bodyBytes));
    }
    throw _toException(r);
  }

  Map<String, dynamic>? _errorBody(http.Response r) {
    try {
      final e = jsonDecode(utf8.decode(r.bodyBytes));
      return e is Map<String, dynamic> ? e : null;
    } catch (_) {
      return null;
    }
  }

  ApiException _toException(http.Response r) {
    final e = _errorBody(r);
    var msg = 'Beklenmeyen hata (${r.statusCode})';
    String? code;
    Expense? current;
    if (e != null) {
      code = e['code'] as String?;
      if (e['error'] is String) msg = _translate(e['error'] as String, code);
      final cur = e['current'];
      if (code == 'conflict' && cur is Map<String, dynamic>) {
        try {
          current = Expense.fromJson(cur);
        } catch (_) {
          // bozuk gövde: çakışma yine bildirilir, güncel kopya olmadan
        }
      }
    }
    return ApiException(
      msg,
      status: r.statusCode,
      code: code,
      retryAfter: (e?['retry_after'] as num?)?.toInt(),
      current: current,
    );
  }

  void _expire() {
    final had = _tokens != null;
    _tokens = null;
    onTokensChanged?.call(null);
    if (had) onUnauthorized?.call();
  }

  /// Access token'ı yenile; tek-uçuşlu: eşzamanlı 401'ler aynı refresh isteğini paylaşır (refresh token tek
  /// kullanımlık olduğundan ikinci bir istek oturumu bozardı).
  Future<bool> _refresh() => _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<bool> _doRefresh() async {
    final t = _tokens;
    if (t == null) return false;
    try {
      final j = await _send(
        'POST',
        _auth,
        '/auth/refresh',
        body: {'refresh_token': t.refresh},
        authed: false,
      );
      setTokens(AuthTokens.fromJson(j as Map<String, dynamic>));
      return true;
    } on ApiException catch (e) {
      if (e.network) rethrow; // bağlantı yokken oturumu düşürme
      return false;
    }
  }

  Future<void> _refreshIfExpiring() async {
    final t = _tokens;
    if (t == null) return;
    if (t.expiresAt.difference(_clock()) > const Duration(seconds: 90)) return;
    if (!await _refresh()) _expire();
  }

  /// Süresi dolmak üzere olan access token'ı önceden yeniler (zamanlayıcı / uygulama öne gelince).
  /// `Image.network` başlıkları senkron okunduğundan görsellerin 15 dk sonra kırılmaması içindir.
  Future<void> ensureFresh() async {
    if (_tokens == null) return;
    try {
      await _refreshIfExpiring();
    } on ApiException {
      // ağ yok: sonraki denemede
    }
  }

  String _translate(String e, String? code) {
    const byCode = {
      'invalid_code': 'Kod hatalı. Tekrar deneyin.',
      'code_expired': 'Kodun süresi doldu. Yeni kod isteyin.',
      'too_many_attempts': 'Çok fazla hatalı deneme. Yeni kod isteyin.',
      'resend_cooldown': 'Yeni kod için biraz bekleyin.',
      'too_many_codes': 'Çok fazla kod istendi, daha sonra tekrar deneyin.',
      'rate_limited': 'Çok fazla deneme. Biraz bekleyip tekrar deneyin.',
      'email_not_verified': 'E-posta adresin henüz doğrulanmadı.',
      'email_taken': 'Bu e-posta zaten kayıtlı.',
      'invalid_email': 'Geçerli bir e-posta girin.',
      'weak_password': 'Şifre en az 8 karakter olmalı; bir rakam ve bir büyük harf içermeli.',
      'invalid_credentials': 'E-posta veya şifre hatalı.',
      'email_send_failed': 'E-posta gönderilemedi. Daha sonra tekrar deneyin.',
      'session_revoked': 'Oturum sonlandırıldı, tekrar giriş yapın.',
      'invalid_refresh': 'Oturum süresi doldu, tekrar giriş yapın.',
      'auth_unavailable': 'Sunucu hazırlanıyor, birkaç saniye sonra tekrar deneyin.',
      'last_profile': 'Son profil silinemez.',
      'conflict': 'Fiş başka bir cihazda değiştirilmiş.',
      'duplicate_document': 'Bu dijital fatura zaten eklenmiş.',
    };
    if (code != null && byCode.containsKey(code)) return byCode[code]!;
    const map = {
      'invalid email': 'Geçerli bir e-posta girin.',
      'email already registered': 'Bu e-posta zaten kayıtlı.',
      'invalid email or password': 'E-posta veya şifre hatalı.',
      'invalid or expired token': 'Oturum süresi doldu, tekrar giriş yapın.',
      'expense not found': 'Fiş bulunamadı.',
      'profile not found': 'Profil bulunamadı.',
      'too many profiles': 'En fazla 20 profil oluşturabilirsiniz.',
      'unknown category_id': 'Geçersiz kategori.',
    };
    return map[e] ?? e;
  }

  // --- Auth ---

  /// Kayıt: e-postaya 6 haneli kod gider. Dönen değer tekrar gönderme bekleme süresidir (sn).
  Future<int> register(String email, String password, {String name = ''}) async {
    final j = await _send(
      'POST',
      _auth,
      '/auth/register',
      body: {'email': email, 'password': password, 'name': name},
      authed: false,
    );
    return ((j as Map)['resend_after_seconds'] as num?)?.toInt() ?? 60;
  }

  Future<AuthSession> verifyEmail(String email, String code) async {
    final d = await _device.info();
    final j = await _send(
      'POST',
      _auth,
      '/auth/verify-email',
      body: {'email': email, 'code': code, 'device_name': d.name, 'platform': d.platform},
      authed: false,
    );
    return _session(j as Map<String, dynamic>);
  }

  /// Kodu yeniden gönderir; cooldown'da [ApiException.retryAfter] kalan saniyeyi taşır.
  Future<int> resendCode(String email) async {
    final j = await _send('POST', _auth, '/auth/resend-code', body: {'email': email}, authed: false);
    return ((j as Map)['resend_after_seconds'] as num?)?.toInt() ?? 60;
  }

  Future<AuthSession> login(String email, String password) async {
    final d = await _device.info();
    final j = await _send(
      'POST',
      _auth,
      '/auth/login',
      body: {'email': email, 'password': password, 'device_name': d.name, 'platform': d.platform},
      authed: false,
    );
    return _session(j as Map<String, dynamic>);
  }

  AuthSession _session(Map<String, dynamic> j) =>
      AuthSession(AuthTokens.fromJson(j), AuthUser.fromJson(j['user'] as Map<String, dynamic>));

  Future<AuthUser> me() async =>
      AuthUser.fromJson(await _send('GET', _auth, '/auth/me') as Map<String, dynamic>);

  Future<int> forgotPassword(String email) async {
    final j = await _send('POST', _auth, '/auth/forgot-password', body: {'email': email}, authed: false);
    return ((j as Map)['resend_after_seconds'] as num?)?.toInt() ?? 60;
  }

  Future<void> resetPassword(String email, String code, String newPassword) => _send(
    'POST',
    _auth,
    '/auth/reset-password',
    body: {'email': email, 'code': code, 'new_password': newPassword},
    authed: false,
  );

  /// Bu cihazın oturumunu sunucuda kapatır (hata olsa da yerel çıkış yapılır).
  Future<void> logout() async {
    final t = _tokens;
    if (t == null) return;
    await _send('POST', _auth, '/auth/logout', body: {'refresh_token': t.refresh}, authed: false);
  }

  Future<List<DeviceSession>> sessions() async {
    final j = await _send('GET', _auth, '/auth/sessions') as List;
    return j.map((e) => DeviceSession.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> revokeSession(String id) => _send('DELETE', _auth, '/auth/sessions/$id');

  Future<void> logoutAll() => _send('POST', _auth, '/auth/logout-all');

  Future<void> deleteAccount(String password) =>
      _send('DELETE', _auth, '/auth/account', body: {'password': password});

  // --- Profiller ---
  Future<List<Profile>> profiles() async {
    final j = await _send('GET', _expense, '/profiles') as List;
    return j.map((e) => Profile.fromServerJson(e as Map<String, dynamic>)).toList();
  }

  /// [clientUid] ile idempotent: aynı uid için mevcut profil döner.
  Future<Profile> createProfile(String name, {String? clientUid}) async => Profile.fromServerJson(
    await _send(
      'POST',
      _expense,
      '/profiles',
      body: {'name': name, 'client_uid': ?clientUid},
    ) as Map<String, dynamic>,
  );

  Future<Profile> renameProfile(int serverId, String name) async => Profile.fromServerJson(
    await _send('PUT', _expense, '/profiles/$serverId', body: {'name': name}) as Map<String, dynamic>,
  );

  Future<void> deleteProfile(int serverId) => _send('DELETE', _expense, '/profiles/$serverId');

  // --- Profil fotoğrafı (profile bağlı, sunucuda saklanır) ---
  /// Avatarı yükler/değiştirir; yeni `avatar_version` döner.
  Future<int> uploadAvatar(int profileServerId, Uint8List bytes) async {
    final j = await _dispatch(
      () {
        final req = http.MultipartRequest('PUT', Uri.parse('$_expense/profiles/$profileServerId/avatar'));
        req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'avatar.jpg'));
        final t = _tokens?.access;
        if (t != null) req.headers['Authorization'] = 'Bearer $t';
        return req;
      },
      timeout: const Duration(seconds: 30),
    ) as Map<String, dynamic>;
    return (j['avatar_version'] as num?)?.toInt() ?? 0;
  }

  Future<void> deleteAvatar(int profileServerId) =>
      _send('DELETE', _expense, '/profiles/$profileServerId/avatar');

  /// `Image.network` adresi; [version] değişince adres değişir ve önbellek kırılır. JWT başlığı [authHeaders].
  String avatarUrl(int profileServerId, int version) =>
      '$_expense/profiles/$profileServerId/avatar?v=$version';

  // --- Expense ---
  Future<List<Category>> categories() async {
    final j = await _send('GET', _expense, '/categories') as List;
    return j.map((e) => Category.fromJson(e)).toList();
  }

  /// Kullanıcının kategori düzeltmelerinden öğrenilen kişisel kurallar (yönetim arayüzü için altyapı).
  Future<List<CategoryRule>> categoryRules() async {
    final j = await _send('GET', _expense, '/category-rules') as List;
    return j.map((e) => CategoryRule.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteCategoryRule(int id) => _send('DELETE', _expense, '/category-rules/$id');

  /// Hesabın tüm fişleri (profil filtresiz): sunucu sayfa başına en çok 200 döner, hepsi çekilir.
  Future<List<Expense>> expenses() => expensesSince(null);

  /// [since] (sunucunun `updated_at` biçiminde, RFC3339) verilirse yalnızca o andan SONRA eklenen/değişen fişler
  /// (artımlı senkron; silinenler için [expenseIds]); null ise tümü. Sayfa başına 200.
  Future<List<Expense>> expensesSince(String? since) async {
    final all = <Expense>[];
    for (var offset = 0;; offset += 200) {
      final j = await _send(
        'GET',
        _expense,
        '/expenses',
        query: {'limit': '200', 'offset': '$offset', 'since': ?since},
      ) as List;
      all.addAll(j.map((e) => Expense.fromJson(e)));
      if (j.length < 200) break;
    }
    return all;
  }

  /// Hesabın sunucudaki TÜM fiş kimlikleri (ucuz): artımlı senkronda silinen fişleri bulmak için.
  Future<List<int>> expenseIds() async {
    final j = await _send('GET', _expense, '/expenses/ids') as Map<String, dynamic>;
    return ((j['ids'] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
  }

  Future<Expense> expense(int id) async =>
      Expense.fromJson(await _send('GET', _expense, '/expenses/$id') as Map<String, dynamic>);

  Future<Expense> createExpense(Map<String, dynamic> body) async =>
      Expense.fromJson(await _send('POST', _expense, '/expenses', body: body));

  Future<Expense> updateExpense(int id, Map<String, dynamic> body) async =>
      Expense.fromJson(await _send('PUT', _expense, '/expenses/$id', body: body));

  Future<void> deleteExpense(int id) => _send('DELETE', _expense, '/expenses/$id');

  /// Toplu, idempotent kayıt (her fişte `client_uid` zorunlu): çevrimdışı kuyruk ve içe aktarma.
  Future<BulkResponse> bulkExpenses(List<Map<String, dynamic>> expenses, {int? profileId}) async {
    final j = await _send(
      'POST',
      _expense,
      '/expenses/bulk',
      body: {'profile_id': ?profileId, 'expenses': expenses},
    ) as Map<String, dynamic>;
    return BulkResponse(
      (j['created'] as num).toInt(),
      (j['skipped'] as num).toInt(),
      (j['failed'] as num).toInt(),
      ((j['results'] as List?) ?? [])
          .map(
            (e) => BulkItemResult(
              (e['index'] as num).toInt(),
              (e['client_uid'] as String?) ?? '',
              e['status'] as String,
              (e['id'] as num?)?.toInt(),
              e['error'] as String?,
            ),
          )
          .toList(),
    );
  }

  // --- Bütçe limitleri (profil + kategori bazlı, aylık) ---
  /// Hesabın tüm profillerinin limitleri (ham JSON; `Budget.fromServerJson` ile çözülür).
  Future<List<Map<String, dynamic>>> budgets() async {
    final j = await _send('GET', _expense, '/budgets') as List;
    return j.cast<Map<String, dynamic>>();
  }

  /// Limit koyar/günceller (profil + kategori başına tek limit). [categoryId] [kTotalBudgetCategoryId] (0)
  /// ise profilin TOPLAM aylık bütçesi (sunucuda `category_id` null).
  Future<Map<String, dynamic>> putBudget(int profileServerId, int categoryId, double limit) async =>
      await _send(
            'PUT',
            _expense,
            '/budgets',
            body: {
              'profile_id': profileServerId,
              if (categoryId != kTotalBudgetCategoryId) 'category_id': categoryId,
              'monthly_limit': limit,
            },
          )
          as Map<String, dynamic>;

  Future<void> deleteBudget(int id) => _send('DELETE', _expense, '/budgets/$id');

  // --- Fiş fotoğrafları (hesaba bağlı, sunucuda saklanır) ---
  /// Bir fişe fotoğraf yükler (tekrarlanan `file` alanı); yeni görsel kimliklerini döner.
  Future<List<int>> uploadImages(int expenseId, List<Uint8List> images) async {
    final j = await _dispatch(
      () {
        final req = http.MultipartRequest('POST', Uri.parse('$_expense/expenses/$expenseId/images'));
        for (var i = 0; i < images.length; i++) {
          req.files.add(http.MultipartFile.fromBytes('file', images[i], filename: 'receipt_$i.jpg'));
        }
        final t = _tokens?.access;
        if (t != null) req.headers['Authorization'] = 'Bearer $t';
        return req;
      },
      timeout: Duration(seconds: 20 + 10 * images.length),
    ) as Map<String, dynamic>;
    return ((j['image_ids'] as List?) ?? []).map((e) => (e as num).toInt()).toList();
  }

  Future<void> deleteImage(int expenseId, int imageId) =>
      _send('DELETE', _expense, '/expenses/$expenseId/images/$imageId');

  /// `Image.network` için adres ve JWT başlığı (görseller yalnızca sahibine açıktır). Başlıktaki access
  /// token [ensureFresh] ile önceden yenilenir.
  String imageUrl(int expenseId, int imageId) => '$_expense/expenses/$expenseId/images/$imageId';
  Map<String, String> get authHeaders => {if (token != null) 'Authorization': 'Bearer $token'};

  // --- OCR & Receipt Parsing ---
  /// Tek çağrı: fiş sayfaları (uzun fişler için birden çok fotoğraf) multipart (binary) olarak JWT'li
  /// expense servisine gider; expense her sayfayı OCR'lar, metinleri birleştirir ve BİR kez ayrıştırır.
  /// Görsel yalnızca işlenmek üzere gönderilir, sunucuda saklanmaz.
  /// Cihazda okunmuş metni sunucu ayrıştırıcısına (kalemler, toplam mutabakatı, kategori kuralları) gönderir.
  /// Yalnızca bulut senkronu AÇIK ve çevrimiçiyken çağrılır (görsel gönderilmez, yalnızca metin).
  Future<ParsedReceipt> parseReceiptText(String text) async {
    final j = await _send('POST', _expense, '/receipts/parse', body: {'text': text}) as Map<String, dynamic>;
    return ParsedReceipt.fromJson(j);
  }

  Future<({OcrResult ocr, ParsedReceipt parsed})> scanReceipt(
    List<Uint8List> pages, {
    String engine = 'paddleocr',
  }) async {
    // Sayfa başına ~25 sn + 20 sn, en fazla 120 sn.
    final secs = (25 * pages.length + 20).clamp(60, 120);
    final j = await _dispatch(
      () {
        final req = http.MultipartRequest('POST', Uri.parse('$_expense/receipts/scan'))
          ..fields['engine'] = engine;
        for (var i = 0; i < pages.length; i++) {
          req.files.add(http.MultipartFile.fromBytes('file', pages[i], filename: 'page_$i.jpg'));
        }
        final t = _tokens?.access;
        if (t != null) req.headers['Authorization'] = 'Bearer $t';
        return req;
      },
      timeout: Duration(seconds: secs),
    ) as Map<String, dynamic>;
    final ocr = OcrResult.fromJson(j['ocr'] as Map<String, dynamic>);
    final failed = ((j['failed_pages'] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    return (
      ocr: failed.isEmpty ? ocr : ocr.withFailedPages(failed),
      parsed: ParsedReceipt.fromJson(j['parsed'] as Map<String, dynamic>),
    );
  }
}
