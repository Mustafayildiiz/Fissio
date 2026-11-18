import 'dart:async';
import 'dart:convert';

import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/app_state.dart';
import 'package:fissio_mobile/data/connectivity.dart';
import 'package:fissio_mobile/data/local_store.dart';
import 'package:fissio_mobile/device_info.dart';
import 'package:fissio_mobile/ocr/ocr_engine.dart';
import 'package:fissio_mobile/theme_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

/// Bellek içi sahte sunucu (auth + expense): gerçek sunucunun JSON sözleşmesini taklit eder. İstekleri
/// kaydeder (`log`), bağlantıyı kesebilir (`offline`) ve belirli yolları geçici olarak reddedebilir.
class FakeBackend {
  bool offline = false;

  /// Her istekten sonra çağrılır (ağın ortada kesilmesini simüle etmek için).
  void Function(String method, String path)? afterRequest;

  final List<({String method, String path})> log = [];
  final Map<String, FakeUser> _users = {};
  final Map<String, int> _tokenUser = {}; // access -> userId
  final Map<String, String> _refresh = {}; // refresh -> access
  final Set<String> _revokedAccess = {};
  final Set<String> _expiredAccess = {};
  int _seq = 0;
  int refreshCalls = 0;
  int avatarUploads = 0;
  int scanCalls = 0;
  String lastCode = '123456';
  final Set<String> failPaths = {}; // "METHOD /path" -> 500
  bool rejectRefresh = false;

  final categories = [
    {'id': 1, 'name': 'Market / Gıda'},
    {'id': 2, 'name': 'Restoran / Kafe'},
    {'id': 11, 'name': 'Diğer'},
  ];

  late final MockClient client = MockClient.streaming((req, body) async {
    final text = await body.bytesToString();
    return _handle(req, text);
  });

  List<String> get writes =>
      [for (final l in log) if (l.method != 'GET') '${l.method} ${l.path}'];

  FakeUser user(String email) => _users[email]!;
  List<Map<String, dynamic>> expensesOf(String email) =>
      _users[email]!.expenses.map((e) => Map<String, dynamic>.of(e)).toList();
  int imageCount(String email, int expenseId) =>
      (_users[email]!.expenses.firstWhere((e) => e['id'] == expenseId)['image_ids'] as List).length;

  /// Access token'ı süresi dolmuş say (refresh ile yenilenebilir).
  void expireAccess(String access) => _expiredAccess.add(access);

  /// Oturum iptal edildi (uzaktan çıkış / hesap silme): refresh de işe yaramaz.
  void revokeSession(String access) => _revokedAccess.add(access);

  /// Doğrulanmış hesap oluşturur (kayıt+kod akışını atlayarak).
  void addUser(String email, String password, {String name = ''}) {
    _users[email] = FakeUser(++_seq, email, password, name);
  }

  http.StreamedResponse _json(int status, Object? body) => http.StreamedResponse(
    Stream.value(utf8.encode(body == null ? '' : jsonEncode(body))),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.StreamedResponse _err(int status, String code, String msg, [Map<String, dynamic>? extra]) =>
      _json(status, {'error': msg, 'code': code, ...?extra});

  Map<String, dynamic> _tokens(FakeUser u) {
    final access = 'acc-${u.id}-${++_seq}';
    final refresh = 'ref-${u.id}-${++_seq}';
    _tokenUser[access] = u.id;
    _refresh[refresh] = access;
    return {
      'access_token': access,
      'refresh_token': refresh,
      'expires_at': DateTime.now().add(const Duration(minutes: 15)).toUtc().toIso8601String(),
      'user': {'id': u.id, 'email': u.email, 'name': u.name},
    };
  }

  FakeUser? _auth(http.BaseRequest req) {
    final h = req.headers['Authorization'];
    if (h == null || !h.startsWith('Bearer ')) return null;
    final t = h.substring(7);
    if (_revokedAccess.contains(t) || _expiredAccess.contains(t)) return null;
    final id = _tokenUser[t];
    return _users.values.where((u) => u.id == id).firstOrNull;
  }

  Future<http.StreamedResponse> _handle(http.BaseRequest req, String body) async {
    final path = req.url.path;
    final m = req.method;
    log.add((method: m, path: path));
    try {
      if (offline) throw http.ClientException('offline');
      if (failPaths.contains('$m $path')) return _err(500, 'internal', 'internal error');
      return await _route(req, m, path, body);
    } finally {
      afterRequest?.call(m, path);
    }
  }

  Future<http.StreamedResponse> _route(http.BaseRequest req, String m, String path, String body) async {
    final j = body.isNotEmpty && body.trimLeft().startsWith('{') ? jsonDecode(body) as Map<String, dynamic> : <String, dynamic>{};
    // ---- auth (kimlik doğrulamasız) ----
    if (path == '/auth/register' && m == 'POST') {
      final email = (j['email'] as String).toLowerCase();
      final u = _users[email];
      if (u != null && u.verified) return _err(409, 'email_taken', 'email already registered');
      _users[email] = FakeUser(++_seq, email, j['password'] as String, (j['name'] as String?) ?? '', verified: false);
      return _json(201, {'email': email, 'verification_required': true, 'resend_after_seconds': 60});
    }
    if (path == '/auth/verify-email' && m == 'POST') {
      final u = _users[j['email']];
      if (u == null) return _err(400, 'invalid_code', 'invalid code');
      if (j['code'] == 'EXPIRED') return _err(400, 'code_expired', 'code expired');
      if (j['code'] != lastCode) return _err(400, 'invalid_code', 'invalid code');
      u.verified = true;
      u.sessions.add(j['device_name'] as String? ?? '');
      return _json(200, _tokens(u));
    }
    if (path == '/auth/resend-code' && m == 'POST') return _json(202, {'resend_after_seconds': 60});
    if (path == '/auth/login' && m == 'POST') {
      final u = _users[(j['email'] as String).toLowerCase()];
      if (u == null || u.password != j['password']) return _err(401, 'invalid_credentials', 'invalid email or password');
      if (!u.verified) return _err(403, 'email_not_verified', 'email not verified');
      u.sessions.add(j['device_name'] as String? ?? '');
      return _json(200, _tokens(u));
    }
    if (path == '/auth/refresh' && m == 'POST') {
      refreshCalls++;
      if (rejectRefresh) return _err(401, 'invalid_refresh', 'invalid refresh token');
      final old = _refresh.remove(j['refresh_token']);
      if (old == null || _revokedAccess.contains(old)) return _err(401, 'invalid_refresh', 'invalid refresh token');
      final id = _tokenUser[old]!;
      _tokenUser.remove(old);
      return _json(200, _tokens(_users.values.firstWhere((u) => u.id == id)));
    }
    if (path == '/auth/logout' && m == 'POST') {
      final old = _refresh.remove(j['refresh_token']);
      if (old != null) _revokedAccess.add(old);
      return _json(204, null);
    }
    if (path == '/auth/forgot-password' || path == '/auth/reset-password') {
      return path.endsWith('forgot-password') ? _json(202, {'resend_after_seconds': 60}) : _json(204, null);
    }

    // ---- kimlik doğrulamalı ----
    final u = _auth(req);
    if (u == null) {
      final t = (req.headers['Authorization'] ?? '').replaceFirst('Bearer ', '');
      if (_revokedAccess.contains(t)) return _err(401, 'session_revoked', 'session revoked');
      return _err(401, 'unauthorized', 'invalid or expired token');
    }

    if (path == '/auth/me') return _json(200, {'id': u.id, 'email': u.email, 'name': u.name, 'email_verified': true});
    if (path == '/auth/sessions') {
      return _json(200, [
        for (var i = 0; i < u.sessions.length; i++)
          {
            'id': 'sess-$i',
            'device_name': u.sessions[i],
            'platform': 'android',
            'ip': '1.1.1.1',
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'last_active_at': DateTime.now().toUtc().toIso8601String(),
            'current': i == u.sessions.length - 1,
          },
      ]);
    }
    if (path == '/auth/account' && m == 'DELETE') {
      if (j['password'] != u.password) return _err(403, 'invalid_credentials', 'invalid password');
      _users.remove(u.email);
      return _json(204, null);
    }
    if (path == '/categories') return _json(200, categories);

    // ---- profiller ----
    if (path == '/profiles' && m == 'GET') {
      if (u.profiles.isEmpty) u.profiles.add({'id': ++_seq, 'name': 'Kişisel', 'client_uid': 'srv-default-${u.id}'});
      return _json(200, u.profiles);
    }
    if (path == '/profiles' && m == 'POST') {
      final uid = (j['client_uid'] as String?) ?? 'srv-${++_seq}';
      final ex = u.profiles.where((p) => p['client_uid'] == uid).firstOrNull;
      if (ex != null) return _json(200, ex);
      final p = {'id': ++_seq, 'name': j['name'], 'client_uid': uid};
      u.profiles.add(p);
      return _json(201, p);
    }
    if (path == '/receipts/scan' && m == 'POST') {
      scanCalls++;
      return _json(200, {
        'ocr': {'raw_text': 'SUNUCU OCR', 'engine': 'paddleocr'},
        'parsed': {
          'merchant': 'SUNUCU MARKET',
          'amount': 10.0,
          'category_id': 1,
          'category_name': 'Market / Gıda',
          'needs_manual': false,
        },
      });
    }
    final am = RegExp(r'^/profiles/(\d+)/avatar$').firstMatch(path);
    if (am != null) {
      final id = int.parse(am[1]!);
      final p = u.profiles.where((p) => p['id'] == id).firstOrNull;
      if (p == null) return _err(404, 'not_found', 'profile not found');
      if (m == 'PUT') {
        avatarUploads++;
        p['avatar_version'] = ((p['avatar_version'] as int?) ?? 0) + 1;
        return _json(200, {'avatar_version': p['avatar_version']});
      }
      if (m == 'DELETE') {
        p['avatar_version'] = 0;
        return _json(200, {'avatar_version': 0});
      }
    }
    final pm = RegExp(r'^/profiles/(\d+)$').firstMatch(path);
    if (pm != null) {
      final id = int.parse(pm[1]!);
      if (m == 'PUT') {
        final p = u.profiles.firstWhere((p) => p['id'] == id);
        p['name'] = j['name'];
        return _json(200, p);
      }
      if (m == 'DELETE') {
        u.profiles.removeWhere((p) => p['id'] == id);
        u.expenses.removeWhere((e) => e['profile_id'] == id);
        return _json(204, null);
      }
    }

    // ---- bütçe limitleri ----
    if (path == '/budgets' && m == 'GET') {
      final pf = int.tryParse(req.url.queryParameters['profile_id'] ?? '');
      return _json(200, [for (final b in u.budgets) if (pf == null || b['profile_id'] == pf) b]);
    }
    if (path == '/budgets' && m == 'PUT') {
      final pid = j['profile_id'] as int;
      if (!u.profiles.any((p) => p['id'] == pid)) return _err(404, 'not_found', 'profile not found');
      final limit = (j['monthly_limit'] as num).toDouble();
      if (limit < 0.01) return _err(400, 'bad_request', 'monthly_limit must be a positive number');
      final ex = u.budgets.where((b) => b['profile_id'] == pid && b['category_id'] == j['category_id']).firstOrNull;
      if (ex != null) {
        ex['monthly_limit'] = limit;
        return _json(200, ex);
      }
      final b = {
        'id': ++_seq,
        'profile_id': pid,
        'category_id': j['category_id'],
        'category_name': _catName(j['category_id']),
        'monthly_limit': limit,
        'spent': 0,
        'status': 'ok',
      };
      u.budgets.add(b);
      return _json(200, b);
    }
    final bm = RegExp(r'^/budgets/(\d+)$').firstMatch(path);
    if (bm != null && m == 'DELETE') {
      final n = u.budgets.length;
      u.budgets.removeWhere((b) => b['id'] == int.parse(bm[1]!));
      return u.budgets.length == n ? _err(404, 'not_found', 'budget not found') : _json(204, null);
    }

    // ---- fişler ----
    if (path == '/expenses' && m == 'GET') {
      final limit = int.tryParse(req.url.queryParameters['limit'] ?? '') ?? 50;
      final off = int.tryParse(req.url.queryParameters['offset'] ?? '') ?? 0;
      final list = u.expenses.reversed.skip(off).take(limit).toList();
      return _json(200, list);
    }
    if (path == '/expenses/bulk' && m == 'POST') {
      final results = <Map<String, dynamic>>[];
      var created = 0, skipped = 0, failed = 0;
      final list = (j['expenses'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < list.length; i++) {
        final e = list[i];
        final uid = e['client_uid'] as String?;
        if (uid == null || e['merchant'] == 'BAD') {
          failed++;
          results.add({'index': i, 'client_uid': uid ?? '', 'status': 'error', 'error': 'invalid'});
          continue;
        }
        final ex = u.expenses.where((x) => x['client_uid'] == uid).firstOrNull;
        if (ex != null) {
          skipped++;
          results.add({'index': i, 'client_uid': uid, 'status': 'skipped', 'id': ex['id']});
          continue;
        }
        final saved = _newExpense(u, e, (e['profile_id'] ?? j['profile_id']) as int);
        created++;
        results.add({'index': i, 'client_uid': uid, 'status': 'created', 'id': saved['id']});
      }
      return _json(200, {'created': created, 'skipped': skipped, 'failed': failed, 'results': results});
    }
    if (path == '/expenses' && m == 'POST') {
      if (j['merchant'] == 'BAD') return _err(400, 'bad_request', 'amount must be a positive number');
      final uid = j['client_uid'] as String?;
      final ex = uid == null ? null : u.expenses.where((x) => x['client_uid'] == uid).firstOrNull;
      if (ex != null) return _json(200, ex);
      return _json(201, _newExpense(u, j, j['profile_id'] as int));
    }
    final em = RegExp(r'^/expenses/(\d+)(/images(?:/(\d+))?)?$').firstMatch(path);
    if (em != null) {
      final id = int.parse(em[1]!);
      final idx = u.expenses.indexWhere((e) => e['id'] == id);
      if (idx < 0) return _err(404, 'not_found', 'expense not found');
      if (em[2] == null) {
        if (m == 'GET') return _json(200, u.expenses[idx]);
        if (m == 'PUT') {
          u.expenses[idx] = {...u.expenses[idx], ...j, 'id': id, 'category_name': _catName(j['category_id'])};
          return _json(200, u.expenses[idx]);
        }
        if (m == 'DELETE') {
          u.expenses.removeAt(idx);
          return _json(204, null);
        }
      } else if (m == 'POST') {
        final n = RegExp('name="file"').allMatches(body).length;
        final ids = u.expenses[idx]['image_ids'] as List;
        final added = [for (var i = 0; i < n; i++) ++_seq];
        ids.addAll(added);
        return _json(201, {'image_ids': added});
      } else if (m == 'DELETE') {
        (u.expenses[idx]['image_ids'] as List).remove(int.parse(em[3]!));
        return _json(204, null);
      }
    }
    return _err(404, 'not_found', 'no route $m $path');
  }

  String _catName(Object? id) =>
      categories.where((c) => c['id'] == id).map((c) => c['name'] as String).firstOrNull ?? 'Diğer';

  Map<String, dynamic> _newExpense(FakeUser u, Map<String, dynamic> j, int profileId) {
    final e = {
      'id': ++_seq,
      'merchant': j['merchant'],
      'amount': j['amount'],
      'date': j['date'],
      'category_id': j['category_id'],
      'category_name': _catName(j['category_id']),
      'note': j['note'] ?? '',
      'items': j['items'] ?? [],
      'image_ids': <int>[],
      'profile_id': profileId,
      'client_uid': j['client_uid'] ?? 'srv-${++_seq}',
      'recurring_day': j['recurring_day'] ?? 0,
      'recurring_remind': j['recurring_remind'] ?? true,
    };
    u.expenses.add(e);
    return e;
  }
}

class FakeUser {
  FakeUser(this.id, this.email, this.password, this.name, {this.verified = true});
  final int id;
  final String email;
  final String password;
  final String name;
  bool verified;
  final List<String> sessions = [];
  final List<Map<String, dynamic>> profiles = [];
  final List<Map<String, dynamic>> expenses = [];
  final List<Map<String, dynamic>> budgets = [];
}

class MemPrefs implements DeletablePrefsStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class FakeConnectivity implements ConnectivityMonitor {
  final _ctrl = StreamController<bool>.broadcast();
  @override
  Stream<bool> get onChanged => _ctrl.stream;
  bool online = true;
  @override
  Future<bool> isOnline() async => online;
  void emit(bool online) => _ctrl.add(online);
}

class FakeDevice implements DeviceInfoProvider {
  @override
  Future<DeviceInfo> info() async => (name: 'Test Phone', platform: 'android');
}

class Harness {
  Harness._(this.backend, this.prefs, this.local, this.connectivity, this.app, this.notifier, this.widget);
  final FakeBackend backend;
  final MemPrefs prefs;
  final MemoryLocalStore local;
  final FakeConnectivity connectivity;
  final AppState app;
  final FakeNotifier notifier;
  final FakeWidgetSync widget;

  factory Harness({
    FakeBackend? backend,
    MemPrefs? prefs,
    MemoryLocalStore? local,
    OcrEngine? onDeviceOcr,
    OcrMode Function()? ocrMode,
    DateTime Function()? clock,
  }) {
    final notifier = FakeNotifier();
    final widget = FakeWidgetSync();
    final b = backend ?? FakeBackend();
    final p = prefs ?? MemPrefs();
    final l = local ?? MemoryLocalStore();
    final c = FakeConnectivity();
    final api = ApiClient(client: b.client, device: FakeDevice(), authBase: 'http://fake-auth', expenseBase: 'http://fake-expense');
    final app = AppState(
      api: api,
      store: p,
      local: l,
      connectivity: c,
      backgroundInterval: const Duration(hours: 1),
      onDeviceOcr: onDeviceOcr,
      ocrMode: ocrMode,
      clock: clock,
      notifier: notifier,
      widgetSync: widget,
    );
    return Harness._(b, p, l, c, app, notifier, widget);
  }

  /// Hesabı sunucuda hazırlar ve giriş yapar.
  Future<void> signIn(String email, {String password = 'Passw0rd1'}) async {
    if (!backend._users.containsKey(email)) backend.addUser(email, password);
    await app.login(email, password);
  }

  /// Ağdaki bekleyen mikro-görevlerin (zamanlayıcısız) bitmesi için.
  Future<void> settle([int times = 20]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}
