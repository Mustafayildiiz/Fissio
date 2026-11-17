import 'dart:typed_data';

class Category {
  final int id;
  final String name;
  const Category(this.id, this.name);
  factory Category.fromJson(Map<String, dynamic> j) =>
      Category(j['id'] as int, j['name'] as String);
}

/// Kullanıcının bir düzeltmesinden öğrenilen kişisel kategori kuralı (işletme ya da kalem adı → kategori).
class CategoryRule {
  final int id;
  final String kind; // 'merchant' | 'item'
  final String pattern;
  final int categoryId;
  final String categoryName;
  final int hits;
  const CategoryRule({
    required this.id,
    required this.kind,
    required this.pattern,
    required this.categoryId,
    required this.categoryName,
    required this.hits,
  });
  factory CategoryRule.fromJson(Map<String, dynamic> j) => CategoryRule(
    id: (j['id'] as num).toInt(),
    kind: (j['kind'] as String?) ?? 'item',
    pattern: (j['pattern'] as String?) ?? '',
    categoryId: (j['category_id'] as num).toInt(),
    categoryName: (j['category_name'] as String?) ?? '',
    hits: (j['hits'] as num?)?.toInt() ?? 1,
  );
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

/// Otomatik kategorilendirmede aday kategori (sunucu `category_candidates`); hızlı seçim için.
class CategoryCandidate {
  final int id;
  final String name;
  final double score;
  const CategoryCandidate(this.id, this.name, this.score);
  factory CategoryCandidate.fromJson(Map<String, dynamic> j) => CategoryCandidate(
    (j['id'] as num).toInt(),
    (j['name'] as String?) ?? '',
    (j['score'] as num?)?.toDouble() ?? 0,
  );
}

class ExpenseItem {
  String name;
  double amount;

  /// Kalem kategorisi (otomatik atanır, kullanıcı değiştirebilir); null = atanmamış.
  int? categoryId;
  String? categoryName;

  /// Taramada otomatik önerilen kalem kategorisi. Kayıtta `categoryId`'den farklıysa sunucu bunu
  /// kullanıcının düzeltmesi sayıp kişisel kural olarak öğrenir.
  int? suggestedCategoryId;

  /// Otomatik atamanın güveni (0-1) ve "güvenilir değil" bayrağı (yalnızca tarama sonucunda).
  double? categoryConfidence;
  bool categoryReview;

  ExpenseItem(
    this.name,
    this.amount, {
    this.categoryId,
    this.categoryName,
    this.suggestedCategoryId,
    this.categoryConfidence,
    this.categoryReview = false,
  });

  factory ExpenseItem.fromJson(Map<String, dynamic> j) {
    final cid = (j['category_id'] as num?)?.toInt();
    return ExpenseItem(
      j['name'] as String,
      (j['amount'] as num).toDouble(),
      categoryId: cid != null && cid > 0 ? cid : null,
      categoryName: j['category_name'] as String?,
      categoryConfidence: (j['category_confidence'] as num?)?.toDouble(),
      categoryReview: (j['category_review'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'amount': amount,
    if (categoryId != null) 'category_id': categoryId,
    if (suggestedCategoryId != null) 'suggested_category_id': suggestedCategoryId,
  };
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
    categoryId: (j['category_id'] as num?)?.toInt() ?? 0,
    categoryName: (j['category_name'] as String?) ?? 'Diğer',
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

  /// Taramada otomatik önerilen fiş kategorisi; kayıtta `categoryId`'den farklıysa kullanıcı düzeltmesi
  /// sayılır ve sunucuda işletme için kişisel kural olarak saklanır.
  int? suggestedCategoryId;

  /// Otomatik kategori güvenilir değil / "Diğer"e düşüldü (sunucu `category_needs_review`). Kullanıcı bir
  /// kategori seçince false olur. [categorySource]: rule | merchant | keyword | items | fallback.
  bool categoryNeedsReview;
  String? categorySource;
  List<CategoryCandidate> categoryCandidates;
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
    this.suggestedCategoryId,
    this.categoryNeedsReview = false,
    this.categorySource,
    this.categoryCandidates = const [],
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

  /// Kategori otomatik atandı ve kullanıcı henüz değiştirmedi.
  bool get categoryAutoAssigned =>
      categorySource != null && suggestedCategoryId != null && categoryId == suggestedCategoryId;

  /// POST/PUT /expenses gövdesi. Fiş ve kalem `suggested_category_id`'leri, kullanıcı otomatik
  /// kategoriyi değiştirdiyse sunucunun kişisel kural öğrenmesi içindir.
  Map<String, dynamic> toRequestBody() => {
    'merchant': merchant,
    'amount': savedAmount,
    'date':
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}',
    'category_id': categoryId,
    if (suggestedCategoryId != null) 'suggested_category_id': suggestedCategoryId,
    'note': note,
    'items': items.map((i) => i.toJson()).toList(),
  };

  factory ReceiptDraft.from(Expense e) {
    final items = e.items.isEmpty
        ? [ExpenseItem(e.merchant.isEmpty ? 'Toplam' : e.merchant, e.amount)]
        : e.items
              .map(
                (i) => ExpenseItem(
                  i.name,
                  i.amount,
                  categoryId: i.categoryId,
                  categoryName: i.categoryName,
                ),
              )
              .toList();
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
    // Otomatik atanan kategori varsayılan seçili gelir; kullanıcı değiştirebilir.
    categoryId: p.categoryId > 0 ? p.categoryId : null,
    suggestedCategoryId: p.categoryId > 0 ? p.categoryId : null,
    categoryNeedsReview: p.categoryNeedsReview,
    categorySource: p.categorySource,
    categoryCandidates: p.categoryCandidates,
    date: p.date ?? DateTime.now(),
    items: p.items.isNotEmpty
        ? p.items
              .map(
                (i) => ExpenseItem(
                  i.name,
                  i.amount,
                  categoryId: i.categoryId,
                  categoryName: i.categoryName,
                  // Kalem kategorisi de öneridir: değiştirilirse kişisel kural olarak öğrenilir.
                  suggestedCategoryId: i.categoryId,
                  categoryConfidence: i.categoryConfidence,
                  categoryReview: i.categoryReview,
                ),
              )
              .toList()
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

  /// Otomatik fiş kategorisi: kaynak (rule|merchant|keyword|items|fallback), "kontrol edin" bayrağı
  /// (`needsReview`'dan, yani toplam uyuşmazlığından AYRI) ve hızlı seçim adayları.
  final String? categorySource;
  final bool categoryNeedsReview;
  final List<CategoryCandidate> categoryCandidates;

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
    this.categorySource,
    this.categoryNeedsReview = false,
    this.categoryCandidates = const [],
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
    categorySource: j['category_source'] as String?,
    categoryNeedsReview: (j['category_needs_review'] as bool?) ?? false,
    categoryCandidates: ((j['category_candidates'] as List?) ?? [])
        .map((e) => CategoryCandidate.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
