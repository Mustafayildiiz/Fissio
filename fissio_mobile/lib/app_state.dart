import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'models.dart';

class AppState extends ChangeNotifier {
  AppState() {
    api = ApiClient(onUnauthorized: _handleUnauthorized);
  }

  late final ApiClient api;
  final _storage = const FlutterSecureStorage();
  static const _tokenKey = 'jwt';

  String? email;
  List<Expense> expenses = [];
  List<Category> categories = [];
  bool loading = false;
  String? error;

  /// 401 geldiğinde UI'ın girişe dönmesi için.
  VoidCallback? onSessionExpired;

  bool get loggedIn => api.token != null;

  /// Kayıtlı token'ı yükler ve doğrular. Geçerliyse true döner.
  Future<bool> restoreSession() async {
    try {
      final t = await _storage.read(key: _tokenKey);
      if (t == null) return false;
      api.token = t;
      email = await api.me();
      return true;
    } on ApiException catch (e) {
      // Ağ hatasında token'ı silme, yalnızca geçersizse sil.
      if (!e.network) await _clear();
      api.token = null;
      return false;
    } catch (_) {
      api.token = null;
      return false;
    }
  }

  Future<void> login(String mail, String password) async {
    final r = await api.login(mail, password);
    api.token = r.token;
    email = r.email;
    await _storage.write(key: _tokenKey, value: r.token);
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
    expenses = [];
    categories = [];
    notifyListeners();
  }

  Future<void> _clear() => _storage.delete(key: _tokenKey);

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

  Future<void> saveDraft(ReceiptDraft d) async {
    final body = {
      'merchant': d.merchant,
      'amount': d.items.fold<double>(0, (s, i) => s + i.amount),
      'date': '${d.date.year.toString().padLeft(4, '0')}-'
          '${d.date.month.toString().padLeft(2, '0')}-'
          '${d.date.day.toString().padLeft(2, '0')}',
      'category_id': d.categoryId,
      'note': d.note,
      'items': d.items.map((i) => i.toJson()).toList(),
    };
    if (d.id == null) {
      await api.createExpense(body);
    } else {
      await api.updateExpense(d.id!, body);
    }
    await refresh();
  }

  Future<void> deleteExpense(int id) async {
    await api.deleteExpense(id);
    await refresh();
  }

  // --- Panel hesapları (son 30 gün) ---
  List<Expense> get lastMonth {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = today.subtract(const Duration(days: 30));
    return expenses.where((e) => !e.date.isBefore(from)).toList();
  }

  double get lastMonthTotal => lastMonth.fold(0.0, (s, e) => s + e.amount);

  Expense? get highestExpense {
    final l = lastMonth;
    if (l.isEmpty) return null;
    return l.reduce((a, b) => a.amount >= b.amount ? a : b);
  }

  ({String name, int id, double total})? get topCategory {
    final m = <int, ({String name, double total})>{};
    for (final e in lastMonth) {
      final cur = m[e.categoryId];
      m[e.categoryId] = (name: e.categoryName, total: (cur?.total ?? 0) + e.amount);
    }
    if (m.isEmpty) return null;
    final best = m.entries.reduce((a, b) => a.value.total >= b.value.total ? a : b);
    return (name: best.value.name, id: best.key, total: best.value.total);
  }
}

final appState = AppState();
