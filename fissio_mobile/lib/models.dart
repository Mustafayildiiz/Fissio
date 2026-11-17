import 'dart:typed_data';

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

  /// Fişe bağlı fotoğraf kimlikleri (sunucuda saklanır, sıralı).
  final List<int> imageIds;

  Expense({
    required this.id,
    required this.merchant,
    required this.amount,
    required this.date,
    required this.categoryId,
    required this.categoryName,
    required this.note,
    required this.items,
    this.imageIds = const [],
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
    imageIds: ((j['image_ids'] as List?) ?? [])
        .map((e) => (e as num).toInt())
        .toList(),
  );
}

/// Kalem toplamından indirim düşülmüş, kaydedilecek fiş tutarı. İndirim yoksa ya da kalemlerden
/// büyükse (kullanıcı kalemleri silmiş/düzeltmiş) kalem toplamı aynen döner.
double netTotal(double itemsTotal, double discount) {
  final net = ((itemsTotal - discount) * 100).round() / 100;
  return discount > 0 && net > 0 ? net : itemsTotal;
}

/// Fiş formu ile ürün ekranı arasında taşınan taslak.
class ReceiptDraft {
  int? id; // null ise yeni fiş
  String merchant;
  int? categoryId;
  DateTime date;
  String note;
  List<ExpenseItem> items;

  /// OCR ile ayrıştırılan fiş toplamı (kalem toplamıyla karşılaştırmak için). Kaydedilen
  /// tutar her zaman kalem toplamıdır; ikisi farklıysa kullanıcıya uyarı gösterilir.
  double? receiptTotal;

  /// Fişteki indirim satırlarının toplamı (kalem değildir; sunucu `discount_total`). Kaydedilen
  /// tutar `kalemler − indirim`dir.
  double discount;

  /// Henüz sunucuya yüklenmemiş fiş fotoğrafları (tarama/çekimden gelir); kayıtta yüklenir.
  List<Uint8List> pendingImages;

  ReceiptDraft({
    this.id,
    this.merchant = '',
    this.categoryId,
    DateTime? date,
    this.note = '',
    List<ExpenseItem>? items,
    this.receiptTotal,
    this.discount = 0,
    List<Uint8List>? pendingImages,
  }) : date = date ?? DateTime.now(),
       items = items ?? [],
       pendingImages = pendingImages ?? [];

  double get itemsTotal => items.fold<double>(0, (s, i) => s + i.amount);

  /// Sunucuya gönderilen fiş tutarı.
  double get savedAmount => netTotal(itemsTotal, discount);

  factory ReceiptDraft.from(Expense e) {
    final items = e.items.isEmpty
        ? [ExpenseItem(e.merchant.isEmpty ? 'Toplam' : e.merchant, e.amount)]
        : e.items.map((i) => ExpenseItem(i.name, i.amount)).toList();
    // İndirim ayrı saklanmaz: kayıtlı tutar kalem toplamından küçükse fark indirimdir.
    final gross = items.fold<double>(0, (s, i) => s + i.amount);
    final diff = ((gross - e.amount) * 100).round() / 100;
    return ReceiptDraft(
      id: e.id,
      merchant: e.merchant,
      categoryId: e.categoryId,
      date: e.date,
      note: e.note,
      items: items,
      discount: diff > 0 ? diff : 0,
    );
  }

  factory ReceiptDraft.fromParsed(ParsedReceipt p) => ReceiptDraft(
    merchant: p.merchant,
    receiptTotal: p.amount,
    // Kalem yoksa tek satır zaten fiş toplamıdır; indirim yalnızca kalemlerden düşülür.
    discount: p.items.isNotEmpty ? p.discountTotal : 0,
    categoryId: p.categoryId > 0 ? p.categoryId : null,
    date: p.date ?? DateTime.now(),
    items: p.items.isNotEmpty
        ? p.items.map((i) => ExpenseItem(i.name, i.amount)).toList()
        : (p.amount != null && p.amount! > 0
              ? [
                  ExpenseItem(
                    p.merchant.isEmpty ? 'Toplam' : p.merchant,
                    p.amount!,
                  ),
                ]
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

  /// Kalem toplamı fiş toplamıyla tutmuyor (sunucu `needs_review`).
  final bool needsReview;

  /// Sunucunun hesapladığı kalem toplamı (`items_total`).
  final double? itemsTotal;

  /// Kalem toplamından düşülecek indirim (`discount_total`; yoksa 0).
  final double discountTotal;

  const ParsedReceipt({
    required this.merchant,
    this.amount,
    this.date,
    required this.categoryId,
    required this.categoryName,
    this.items = const [],
    required this.needsManual,
    this.needsReview = false,
    this.itemsTotal,
    this.discountTotal = 0,
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
    needsReview: (j['needs_review'] as bool?) ?? false,
    itemsTotal: (j['items_total'] as num?)?.toDouble(),
    discountTotal: (j['discount_total'] as num?)?.toDouble() ?? 0,
  );
}
