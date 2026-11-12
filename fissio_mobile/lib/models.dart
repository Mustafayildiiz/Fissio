class Category {
  final int id;
  final String name;
  const Category(this.id, this.name);
  factory Category.fromJson(Map<String, dynamic> j) =>
      Category(j['id'] as int, j['name'] as String);
}

class UserProfile {
  final String id;
  final String name;
  final String email;
  final String password;
  final String? token;

  const UserProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.password,
    this.token,
  });

  UserProfile copyWith({
    String? name,
    String? email,
    String? password,
    String? token,
  }) => UserProfile(
    id: id,
    name: name ?? this.name,
    email: email ?? this.email,
    password: password ?? this.password,
    token: token ?? this.token,
  );

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
    id: j['id'] as String,
    name: j['name'] as String,
    email: j['email'] as String,
    password: j['password'] as String,
    token: j['token'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'password': password,
    'token': token,
  };
}

class ExpenseItem {
  String name;
  double amount;
  ExpenseItem(this.name, this.amount);
  factory ExpenseItem.fromJson(Map<String, dynamic> j) =>
      ExpenseItem(j['name'] as String, (j['amount'] as num).toDouble());
  Map<String, dynamic> toJson() => {'name': name, 'amount': amount};
}

class Expense {
  final int id;
  final String merchant;
  final double amount;
  final DateTime date;
  final int categoryId;
  final String categoryName;
  final String note;
  final List<ExpenseItem> items;

  Expense({
    required this.id,
    required this.merchant,
    required this.amount,
    required this.date,
    required this.categoryId,
    required this.categoryName,
    required this.note,
    required this.items,
  });

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
    id: j['id'] as int,
    merchant: j['merchant'] as String,
    amount: (j['amount'] as num).toDouble(),
    date: DateTime.parse(j['date'] as String),
    categoryId: j['category_id'] as int,
    categoryName: j['category_name'] as String,
    note: (j['note'] as String?) ?? '',
    items: ((j['items'] as List?) ?? [])
        .map((e) => ExpenseItem.fromJson(e))
        .toList(),
  );
}

/// Fiş formu ile ürün ekranı arasında taşınan taslak.
class ReceiptDraft {
  int? id; // null ise yeni fiş
  String merchant;
  int? categoryId;
  DateTime date;
  String note;
  List<ExpenseItem> items;

  ReceiptDraft({
    this.id,
    this.merchant = '',
    this.categoryId,
    DateTime? date,
    this.note = '',
    List<ExpenseItem>? items,
  }) : date = date ?? DateTime.now(),
       items = items ?? [];

  factory ReceiptDraft.from(Expense e) => ReceiptDraft(
    id: e.id,
    merchant: e.merchant,
    categoryId: e.categoryId,
    date: e.date,
    note: e.note,
    items: e.items.isEmpty
        ? [ExpenseItem(e.merchant.isEmpty ? 'Toplam' : e.merchant, e.amount)]
        : e.items.map((i) => ExpenseItem(i.name, i.amount)).toList(),
  );

  factory ReceiptDraft.fromParsed(ParsedReceipt p) => ReceiptDraft(
    merchant: p.merchant,
    categoryId: p.categoryId > 0 ? p.categoryId : null,
    date: p.date ?? DateTime.now(),
    items: p.items.isNotEmpty
        ? p.items.map((i) => ExpenseItem(i.name, i.amount)).toList()
        : (p.amount != null && p.amount! > 0
              ? [ExpenseItem(p.merchant.isEmpty ? 'Toplam' : p.merchant, p.amount!)]
              : []),
  );
}

class ParsedReceipt {
  final String merchant;
  final double? amount;
  final DateTime? date;
  final int categoryId;
  final String categoryName;
  final List<ExpenseItem> items;
  final bool needsManual;

  const ParsedReceipt({
    required this.merchant,
    this.amount,
    this.date,
    required this.categoryId,
    required this.categoryName,
    this.items = const [],
    required this.needsManual,
  });

  factory ParsedReceipt.fromJson(Map<String, dynamic> j) => ParsedReceipt(
    merchant: (j['merchant'] as String?) ?? '',
    amount: (j['amount'] as num?)?.toDouble(),
    date: j['date'] is String ? DateTime.tryParse(j['date'] as String) : null,
    categoryId: (j['category_id'] as int?) ?? 0,
    categoryName: (j['category_name'] as String?) ?? 'Diğer',
    items: ((j['items'] as List?) ?? [])
        .map((e) => ExpenseItem.fromJson(e as Map<String, dynamic>))
        .toList(),
    needsManual: (j['needs_manual'] as bool?) ?? false,
  );
}
