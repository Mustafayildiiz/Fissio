import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'models.dart';
import 'ocr/ocr_engine.dart';

class ApiException implements Exception {
  final String message;
  final int? status;
  final bool network;
  ApiException(this.message, {this.status, this.network = false});
  @override
  String toString() => message;
}

/// Gerçek cihazda: `flutter run --dart-define=API_HOST=192.168.x.x`.
/// Tanımlı değilse Android emülatöründe host makine 10.0.2.2, diğerlerinde localhost.
const _hostOverride = String.fromEnvironment('API_HOST');
String get _host {
  if (_hostOverride.isNotEmpty) return _hostOverride;
  return (!kIsWeb && Platform.isAndroid) ? '10.0.2.2' : 'localhost';
}

class ApiClient {
  ApiClient({this.onUnauthorized});

  String? token;
  final void Function()? onUnauthorized;

  final String _auth = 'http://$_host:8081';
  final String _expense = 'http://$_host:8082';

  Future<dynamic> _send(
    String method,
    String base,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null) headers['Authorization'] = 'Bearer $token';

    final req = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);
    return _dispatch(req);
  }

  /// İsteği gönderir; ağ hatası, 401 ve hata gövdesi çevirisini tek yerde işler.
  Future<dynamic> _dispatch(
    http.BaseRequest req, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    http.Response r;
    try {
      r = await http.Response.fromStream(await req.send().timeout(timeout));
    } catch (_) {
      // SRS: ağ kesintisinde işlem kuyruğa alınmaz, anlık hata bildirilir.
      throw ApiException(
        'Sunucuya ulaşılamıyor. İnternet bağlantınızı kontrol edin.',
        network: true,
      );
    }

    if (r.statusCode == 401 && token != null) {
      onUnauthorized?.call();
    }
    if (r.statusCode >= 200 && r.statusCode < 300) {
      if (r.body.isEmpty) return null;
      return jsonDecode(utf8.decode(r.bodyBytes));
    }
    var msg = 'Beklenmeyen hata (${r.statusCode})';
    try {
      final e = jsonDecode(utf8.decode(r.bodyBytes));
      if (e is Map && e['error'] is String) msg = _translate(e['error']);
    } catch (_) {}
    throw ApiException(msg, status: r.statusCode);
  }

  String _translate(String e) {
    const map = {
      'invalid email': 'Geçerli bir e-posta girin.',
      'password must be 6-72 characters': 'Şifre 6-72 karakter olmalı.',
      'email already registered': 'Bu e-posta zaten kayıtlı.',
      'invalid email or password': 'E-posta veya şifre hatalı.',
      'invalid or expired token': 'Oturum süresi doldu, tekrar giriş yapın.',
      'expense not found': 'Fiş bulunamadı.',
      'unknown category_id': 'Geçersiz kategori.',
    };
    return map[e] ?? e;
  }

  // --- Auth ---
  Future<void> register(String email, String password) => _send(
    'POST',
    _auth,
    '/auth/register',
    body: {'email': email, 'password': password},
  );

  Future<({String token, String email})> login(
    String email,
    String password,
  ) async {
    final j = await _send(
      'POST',
      _auth,
      '/auth/login',
      body: {'email': email, 'password': password},
    );
    return (token: j['token'] as String, email: j['user']['email'] as String);
  }

  Future<String> me() async {
    final j = await _send('GET', _auth, '/auth/me');
    return j['email'] as String;
  }

  // --- Expense ---
  Future<List<Category>> categories() async {
    final j = await _send('GET', _expense, '/categories') as List;
    return j.map((e) => Category.fromJson(e)).toList();
  }

  Future<List<Expense>> expenses() async {
    final j = await _send(
      'GET',
      _expense,
      '/expenses',
      query: {'limit': '200'},
    ) as List;
    return j.map((e) => Expense.fromJson(e)).toList();
  }

  Future<Expense> createExpense(Map<String, dynamic> body) async =>
      Expense.fromJson(await _send('POST', _expense, '/expenses', body: body));

  Future<Expense> updateExpense(int id, Map<String, dynamic> body) async =>
      Expense.fromJson(
        await _send('PUT', _expense, '/expenses/$id', body: body),
      );

  Future<void> deleteExpense(int id) =>
      _send('DELETE', _expense, '/expenses/$id');

  // --- Fiş fotoğrafları (hesaba bağlı, sunucuda saklanır) ---
  /// Bir fişe fotoğraf yükler (tekrarlanan `file` alanı); yeni görsel kimliklerini döner.
  Future<List<int>> uploadImages(int expenseId, List<Uint8List> images) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('$_expense/expenses/$expenseId/images'),
    );
    for (var i = 0; i < images.length; i++) {
      req.files.add(
        http.MultipartFile.fromBytes(
          'file',
          images[i],
          filename: 'receipt_$i.jpg',
        ),
      );
    }
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    final j = await _dispatch(
      req,
      timeout: Duration(seconds: 20 + 10 * images.length),
    ) as Map<String, dynamic>;
    return ((j['image_ids'] as List?) ?? [])
        .map((e) => (e as num).toInt())
        .toList();
  }

  Future<void> deleteImage(int expenseId, int imageId) =>
      _send('DELETE', _expense, '/expenses/$expenseId/images/$imageId');

  /// `Image.network` için adres ve JWT başlığı (görseller yalnızca sahibine açıktır).
  String imageUrl(int expenseId, int imageId) =>
      '$_expense/expenses/$expenseId/images/$imageId';
  Map<String, String> get authHeaders => {
    if (token != null) 'Authorization': 'Bearer $token',
  };

  // --- OCR & Receipt Parsing ---
  /// Tek çağrı: fiş sayfaları (uzun fişler için birden çok fotoğraf) multipart (binary) olarak JWT'li
  /// expense servisine gider; expense her sayfayı OCR'lar, metinleri birleştirir ve BİR kez ayrıştırır.
  Future<({OcrResult ocr, ParsedReceipt parsed})> scanReceipt(
    List<Uint8List> pages, {
    String engine = 'paddleocr',
  }) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('$_expense/receipts/scan'),
    )..fields['engine'] = engine;
    for (var i = 0; i < pages.length; i++) {
      req.files.add(
        http.MultipartFile.fromBytes('file', pages[i], filename: 'page_$i.jpg'),
      );
    }
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    // Sayfa başına ~25 sn + 20 sn, en fazla 120 sn.
    final secs = (25 * pages.length + 20).clamp(60, 120);
    final j = await _dispatch(
      req,
      timeout: Duration(seconds: secs),
    ) as Map<String, dynamic>;
    return (
      ocr: OcrResult.fromJson(j['ocr'] as Map<String, dynamic>),
      parsed: ParsedReceipt.fromJson(j['parsed'] as Map<String, dynamic>),
    );
  }
}
