class Category {
  final int id;
  final String name;
  const Category(this.id, this.name);
  factory Category.fromJson(Map<String, dynamic> j) =>
      Category(j['id'] as int, j['name'] as String);
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
  })  : date = date ?? DateTime.now(),
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
}

