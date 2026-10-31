import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  final String message;
  final int? status;
  final bool network;
  ApiException(this.message, {this.status, this.network = false});
  @override
  String toString() => message;
}

/// Android emülatöründe host makine 10.0.2.2 adresidir.
String get _host => (!kIsWeb && Platform.isAndroid) ? '10.0.2.2' : 'localhost';

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

    http.Response r;
    try {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      r = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 10)),
      );
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
}

