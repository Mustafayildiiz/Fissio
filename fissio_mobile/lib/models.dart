import 'dart:typed_data';

/// Sunucudaki sabit sınıflandırmanın "Diğer" kategorisi (kategori bulunamayınca / cihaz taramasında varsayılan).
const String kOtherCategory = 'Diğer';

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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

/// Profil + kategori bazlı aylık harcama limiti. [profileUid] = [Profile.id] (client_uid). [serverId] bulutta
/// kayıtlıysa sunucu kimliği; [state] fişlerle aynı anlamdadır (synced / pending / localOnly).
/// [Budget.categoryId] değeri: kategori değil, profilin TOPLAM aylık bütçesi (tüm kategorilerin toplamı).
const kTotalBudgetCategoryId = 0;

/// Toplam bütçenin görünen adı.
const kTotalBudgetName = 'Toplam bütçe';

class Budget {
  final String profileUid;

  /// Kategori kimliği; [kTotalBudgetCategoryId] (0) = profilin toplam aylık bütçesi.
  final int categoryId;
  final String categoryName;
  final double limit;
  final int? serverId;
  final SyncState state;
  const Budget({
    required this.profileUid,
    required this.categoryId,
    required this.categoryName,
    required this.limit,
    this.serverId,
    this.state = SyncState.synced,
  });

  bool get isTotal => categoryId == kTotalBudgetCategoryId;

  Budget copyWith({double? limit, int? serverId, SyncState? state, String? categoryName}) => Budget(
    profileUid: profileUid,
    categoryId: categoryId,
    categoryName: categoryName ?? this.categoryName,
    limit: limit ?? this.limit,
    serverId: serverId ?? this.serverId,
    state: state ?? this.state,
  );

  /// Sunucu yanıtı; `profile_id` sayısal kimliğinden [profileUid] çözülür (bilinmiyorsa null döner).
  static Budget? fromServerJson(Map<String, dynamic> j, String? Function(int serverProfileId) uidOf) {
    final uid = uidOf((j['profile_id'] as num).toInt());
    if (uid == null) return null;
    return Budget(
      profileUid: uid,
      // Sunucuda toplam bütçe `category_id: null` ile gelir.
      categoryId: (j['category_id'] as num?)?.toInt() ?? kTotalBudgetCategoryId,
      categoryName: (j['category_name'] as String?) ?? (j['category_id'] == null ? kTotalBudgetName : ''),
      limit: (j['monthly_limit'] as num).toDouble(),
      serverId: (j['id'] as num?)?.toInt(),
    );
  }

  factory Budget.fromLocalJson(Map<String, dynamic> j) => Budget(
    profileUid: j['profile_uid'] as String,
    categoryId: (j['category_id'] as num).toInt(),
    categoryName: (j['category_name'] as String?) ?? '',
    limit: (j['limit'] as num).toDouble(),
    serverId: (j['server_id'] as num?)?.toInt(),
    state: syncStateFrom(j['state'] as String?),
  );

  Map<String, dynamic> toLocalJson() => {
    'profile_uid': profileUid,
    'category_id': categoryId,
    'category_name': categoryName,
    'limit': limit,
    if (serverId != null) 'server_id': serverId,
    'state': state.name,
  };
}

/// Tekrarlayan giderin türü: [fixed] her ay aynı tutar (kira, abonelik); [variable] tutarı her ay değişen
/// fatura (elektrik, su, doğalgaz) — projeksiyonda geçmiş ayların hareketli ortalaması / tahmini tutar kullanılır.
enum RecurringKind { fixed, variable }

RecurringKind recurringKindFrom(String? v) => v == 'variable' ? RecurringKind.variable : RecurringKind.fixed;

/// Kaydın bulutla ilişkisi: [synced] sunucuda; [pending] bulut senkronu açıkken henüz yüklenmedi
/// (çevrimdışı kuyruk, bağlantı gelince otomatik yüklenir); [localOnly] senkron kapalıyken yalnızca
/// cihazda (kullanıcı senkronu açana kadar sunucuya hiçbir koşulda gönderilmez).
enum SyncState { synced, pending, localOnly }

SyncState syncStateFrom(String? v) => switch (v) {
  'pending' => SyncState.pending,
  'localOnly' => SyncState.localOnly,
  _ => SyncState.synced,
};

/// Giriş yapmış hesap (sunucudan; şifre asla saklanmaz).
class AuthUser {
  final int id;
  final String email;
  final String name;
  const AuthUser({required this.id, required this.email, this.name = ''});

  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
    id: (j['id'] as num).toInt(),
    email: (j['email'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
  );

  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'name': name};
}

/// Hesaba bağlı profil (Kişisel, Ev, İş...). [id] istemci kimliğidir (`client_uid`): hem sunucudaki hem
/// henüz yüklenmemiş yerel profiller için aynıdır; böylece senkron idempotent olur.
class Profile {
  final String id;
  final String name;

  /// Sunucudaki sayısal kimlik; henüz yüklenmemiş profillerde null.
  final int? serverId;
  final SyncState state;

  /// Sunucudaki avatar sürümü; 0 = sunucuda avatar yok. Görsel `api.avatarUrl` ile okunur.
  final int avatarVersion;

  /// Cihazdaki avatar dosyası (yerel depo yolu). Doluysa görüntülenen odur: senkron kapalıyken ya da
  /// çevrimdışıyken seçilen avatar burada bekler ve senkron açıkken yüklenip temizlenir.
  final String? localAvatarPath;

  const Profile({
    required this.id,
    required this.name,
    this.serverId,
    this.state = SyncState.synced,
    this.avatarVersion = 0,
    this.localAvatarPath,
  });

  bool get hasAvatar => localAvatarPath != null || (serverId != null && avatarVersion > 0);

  Profile copyWith({
    String? name,
    int? serverId,
    SyncState? state,
    int? avatarVersion,
    String? localAvatarPath,
    bool clearLocalAvatar = false,
  }) => Profile(
    id: id,
    name: name ?? this.name,
    serverId: serverId ?? this.serverId,
    state: state ?? this.state,
    avatarVersion: avatarVersion ?? this.avatarVersion,
    localAvatarPath: clearLocalAvatar ? null : (localAvatarPath ?? this.localAvatarPath),
  );

  factory Profile.fromServerJson(Map<String, dynamic> j) => Profile(
    id: j['client_uid'] as String,
    name: j['name'] as String,
    serverId: (j['id'] as num).toInt(),
    avatarVersion: (j['avatar_version'] as num?)?.toInt() ?? 0,
  );

  factory Profile.fromLocalJson(Map<String, dynamic> j) => Profile(
    id: j['id'] as String,
    name: j['name'] as String,
    serverId: (j['server_id'] as num?)?.toInt(),
    state: syncStateFrom(j['state'] as String?),
    avatarVersion: (j['avatar_version'] as num?)?.toInt() ?? 0,
    localAvatarPath: j['local_avatar'] as String?,
  );

  Map<String, dynamic> toLocalJson() => {
    'id': id,
    'name': name,
    if (serverId != null) 'server_id': serverId,
    'state': state.name,
    if (avatarVersion > 0) 'avatar_version': avatarVersion,
    if (localAvatarPath != null) 'local_avatar': localAvatarPath,
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
  /// Sunucu fişlerinde sunucu kimliği (>0); yalnızca cihazdaki fişlerde negatif yerel kimlik.
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

  /// Hesap genelinde tekil kalıcı kimlik (`client_uid`): çevrimdışı kuyruk tekrarı ve içe aktarma
  /// mükerrer kayıt üretmesin diye.
  final String clientUid;

  /// Fişin profili: istemci kimliği ([Profile.id]) ve (biliniyorsa) sunucu kimliği.
  final String profileUid;
  final int? profileServerId;

  final SyncState syncState;

  /// Yalnızca cihazdaki (henüz yüklenmemiş) fişin fotoğraf dosya yolları.
  final List<String> localImages;

  /// Taramada önerilen fiş kategorisi (yerel fişte, yüklenirken sunucunun kural öğrenmesi için saklanır).
  final int? suggestedCategoryId;

  /// "Her ay tekrarlanır": aylık ödeme günü (1-31), 0 = tekrarlamaz. [recurringRemind] ödeme hatırlatıcı
  /// tercihidir. Seri/projeksiyon hesabı `recurring.dart`'ta.
  final int recurringDay;
  final bool recurringRemind;

  /// Tekrar türü (sabit / değişken fatura) ve değişken fatura için kullanıcının tahmini tutarı (0 = yok).
  final RecurringKind recurringKind;
  final double recurringEstimate;

  /// Kuyruktaki fişin buluta gönderilemeyen (ağ dışı: sunucu reddi / hata) deneme sayısı ve son hata iletisi.
  /// Başarısız kayıt kuyruğu kilitlemez; kullanıcı görür, düzenleyebilir ya da silebilir.
  final int syncFailures;
  final String? syncError;

  /// Sunucunun `updated_at` değeri, AYNEN (ham metin; mikrosaniye hassasiyeti `base_updated_at` / `since` için
  /// korunur). Bekleyen düzenlemede ([LocalSnapshot.pendingEdits]) düzenlemenin dayandığı sunucu sürümüdür.
  final String? updatedAt;

  /// Fişi okuyan OCR motoru (`paddleocr` | `custom` | `mlkit`); manuel girilen ve eski kayıtlarda null.
  /// Yalnızca bilgi amaçlıdır (fiş detayında gösterilir), düzenlemede korunur.
  final String? ocrEngine;

  /// Dijital fatura kimliği (ETTN UUID'si ya da `VKN_FaturaNo`); yalnızca PDF/e-fatura içe aktarmada dolar, mükerrer
  /// eklemeyi önler (sunucuda hesap içinde tekil). Fiş/manuel kayıtta null.
  final String? documentNo;

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
    this.clientUid = '',
    this.profileUid = '',
    this.profileServerId,
    this.syncState = SyncState.synced,
    this.localImages = const [],
    this.suggestedCategoryId,
    this.recurringDay = 0,
    this.recurringRemind = true,
    this.recurringKind = RecurringKind.fixed,
    this.recurringEstimate = 0,
    this.syncFailures = 0,
    this.syncError,
    this.updatedAt,
    this.ocrEngine,
    this.documentNo,
  });

  bool get isRecurring => recurringDay > 0;

  /// Çevrimdışı düzenleme sunucudaki daha yeni bir sürümle çakıştı (409): kullanıcı çözene kadar yeniden gönderilmez.
  bool get isEditConflict => syncError == kEditConflict;
  bool get isLocal => syncState != SyncState.synced;
  int get imageCount => imageIds.length + localImages.length;

  Expense copyWith({
    int? id,
    String? merchant,
    double? amount,
    DateTime? date,
    int? categoryId,
    String? categoryName,
    String? note,
    List<ExpenseItem>? items,
    List<int>? imageIds,
    String? clientUid,
    String? profileUid,
    int? profileServerId,
    SyncState? syncState,
    List<String>? localImages,
    int? suggestedCategoryId,
    int? recurringDay,
    bool? recurringRemind,
    RecurringKind? recurringKind,
    double? recurringEstimate,
    int? syncFailures,
    String? syncError,
    bool clearSyncError = false,
    String? updatedAt,
    String? ocrEngine,
    String? documentNo,
  }) => Expense(
    id: id ?? this.id,
    merchant: merchant ?? this.merchant,
    amount: amount ?? this.amount,
    date: date ?? this.date,
    categoryId: categoryId ?? this.categoryId,
    categoryName: categoryName ?? this.categoryName,
    note: note ?? this.note,
    items: items ?? this.items,
    imageIds: imageIds ?? this.imageIds,
    clientUid: clientUid ?? this.clientUid,
    profileUid: profileUid ?? this.profileUid,
    profileServerId: profileServerId ?? this.profileServerId,
    syncState: syncState ?? this.syncState,
    localImages: localImages ?? this.localImages,
    suggestedCategoryId: suggestedCategoryId ?? this.suggestedCategoryId,
    recurringDay: recurringDay ?? this.recurringDay,
    recurringRemind: recurringRemind ?? this.recurringRemind,
    recurringKind: recurringKind ?? this.recurringKind,
    recurringEstimate: recurringEstimate ?? this.recurringEstimate,
    syncFailures: clearSyncError ? 0 : (syncFailures ?? this.syncFailures),
    syncError: clearSyncError ? null : (syncError ?? this.syncError),
    updatedAt: updatedAt ?? this.updatedAt,
    ocrEngine: ocrEngine ?? this.ocrEngine,
    documentNo: documentNo ?? this.documentNo,
  );

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
    id: j['id'] as int,
    merchant: j['merchant'] as String,
    amount: (j['amount'] as num).toDouble(),
    date: DateTime.parse(j['date'] as String),
    categoryId: (j['category_id'] as num?)?.toInt() ?? 0,
    categoryName: (j['category_name'] as String?) ?? kOtherCategory,
    note: (j['note'] as String?) ?? '',
    items: ((j['items'] as List?) ?? [])
        .map((e) => ExpenseItem.fromJson(e))
        .toList(),
    imageIds: ((j['image_ids'] as List?) ?? [])
        .map((e) => (e as num).toInt())
        .toList(),
    clientUid: (j['client_uid'] as String?) ?? '',
    profileServerId: (j['profile_id'] as num?)?.toInt(),
    recurringDay: (j['recurring_day'] as num?)?.toInt() ?? 0,
    recurringRemind: (j['recurring_remind'] as bool?) ?? true,
    recurringKind: recurringKindFrom(j['recurring_kind'] as String?),
    recurringEstimate: (j['recurring_estimate'] as num?)?.toDouble() ?? 0,
    updatedAt: j['updated_at'] as String?,
    ocrEngine: j['ocr_engine'] as String?,
    documentNo: j['document_no'] as String?,
  );

  /// Cihazda saklanan (yüklenmemiş) fiş kaydı.
  Map<String, dynamic> toLocalJson() => {
    'id': id,
    'merchant': merchant,
    'amount': amount,
    'date': _isoDate(date),
    'category_id': categoryId,
    'category_name': categoryName,
    'note': note,
    'items': items.map((i) => i.toJson()..['category_name'] = i.categoryName).toList(),
    'client_uid': clientUid,
    'profile_uid': profileUid,
    if (profileServerId != null) 'profile_server_id': profileServerId,
    'state': syncState.name,
    'images': localImages,
    if (suggestedCategoryId != null) 'suggested_category_id': suggestedCategoryId,
    if (recurringDay > 0) 'recurring_day': recurringDay,
    if (recurringDay > 0) 'recurring_remind': recurringRemind,
    if (recurringDay > 0) 'recurring_kind': recurringKind.name,
    if (recurringEstimate > 0) 'recurring_estimate': recurringEstimate,
    if (syncFailures > 0) 'sync_failures': syncFailures,
    if (syncError != null) 'sync_error': syncError,
    // Sunucudan önbelleğe alınan (senkronlanmış) fişlerin fotoğraf kimlikleri.
    if (imageIds.isNotEmpty) 'image_ids': imageIds,
    if (updatedAt != null) 'updated_at': updatedAt,
    if (ocrEngine != null) 'ocr_engine': ocrEngine,
    if (documentNo != null) 'document_no': documentNo,
  };

  factory Expense.fromLocalJson(Map<String, dynamic> j) {
    final items = ((j['items'] as List?) ?? []).map((e) {
      final m = e as Map<String, dynamic>;
      return ExpenseItem.fromJson(m)
        ..suggestedCategoryId = (m['suggested_category_id'] as num?)?.toInt();
    }).toList();
    return Expense(
      id: (j['id'] as num).toInt(),
      merchant: (j['merchant'] as String?) ?? '',
      amount: (j['amount'] as num).toDouble(),
      date: DateTime.parse(j['date'] as String),
      categoryId: (j['category_id'] as num?)?.toInt() ?? 0,
      categoryName: (j['category_name'] as String?) ?? kOtherCategory,
      note: (j['note'] as String?) ?? '',
      items: items,
      clientUid: j['client_uid'] as String,
      profileUid: (j['profile_uid'] as String?) ?? '',
      profileServerId: (j['profile_server_id'] as num?)?.toInt(),
      syncState: syncStateFrom(j['state'] as String?),
      localImages: ((j['images'] as List?) ?? []).cast<String>(),
      suggestedCategoryId: (j['suggested_category_id'] as num?)?.toInt(),
      recurringDay: (j['recurring_day'] as num?)?.toInt() ?? 0,
      recurringRemind: (j['recurring_remind'] as bool?) ?? true,
      recurringKind: recurringKindFrom(j['recurring_kind'] as String?),
      recurringEstimate: (j['recurring_estimate'] as num?)?.toDouble() ?? 0,
      syncFailures: (j['sync_failures'] as num?)?.toInt() ?? 0,
      syncError: j['sync_error'] as String?,
      imageIds: ((j['image_ids'] as List?) ?? []).map((e) => (e as num).toInt()).toList(),
      updatedAt: j['updated_at'] as String?,
      ocrEngine: j['ocr_engine'] as String?,
      documentNo: j['document_no'] as String?,
    );
  }
}

/// [Expense.syncError] işareti: çevrimdışı düzenleme sunucudaki daha yeni sürümle çakıştı (bkz. [Expense.isEditConflict]).
const kEditConflict = 'conflict';

/// Kalem toplamından indirim düşülmüş, kaydedilecek fiş tutarı. İndirim yoksa ya da kalemlerden
/// büyükse (kullanıcı kalemleri silmiş/düzeltmiş) kalem toplamı aynen döner.
double netTotal(double itemsTotal, double discount) {
  final net = ((itemsTotal - discount) * 100).round() / 100;
  return discount > 0 && net > 0 ? net : itemsTotal;
}

/// Fiş formu ile ürün ekranı arasında taşınan taslak.
class ReceiptDraft {
  int? id; // null ise yeni fiş

  /// Düzenlenen fişin kalıcı kimliği (yeni fişte kayıt sırasında üretilir).
  String? clientUid;
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

  /// "Her ay tekrarlanır" seçeneği: aylık ödeme günü (1-31), 0 = tekrarlamaz; hatırlatıcı tercihi.
  int recurringDay;
  bool recurringRemind;

  /// Sabit tutarlı mı, değişken fatura mı; değişken için isteğe bağlı tahmini aylık tutar (0 = yok).
  RecurringKind recurringKind;
  double recurringEstimate;

  /// Taramada fişi okuyan motor (bkz. [Expense.ocrEngine]); manuel girişte null. Kayıtta sunucuya/cihaza yazılır.
  String? ocrEngine;

  /// Dijital fatura kimliği (bkz. [Expense.documentNo]); yalnızca PDF/e-fatura içe aktarmada.
  String? documentNo;

  ReceiptDraft({
    this.id,
    this.clientUid,
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
    this.recurringDay = 0,
    this.recurringRemind = true,
    this.recurringKind = RecurringKind.fixed,
    this.recurringEstimate = 0,
    this.ocrEngine,
    this.documentNo,
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
    if (clientUid != null) 'client_uid': clientUid,
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
    // 0 = tekrarlamaz (güncellemede işareti kaldırır).
    'recurring_day': recurringDay,
    'recurring_remind': recurringRemind,
    'recurring_kind': recurringKind.name,
    // 0 = tahmin yok (güncellemede kaldırır); yalnızca tekrarlayan değişken faturada anlamlıdır.
    'recurring_estimate': recurringDay > 0 && recurringKind == RecurringKind.variable ? recurringEstimate : 0,
    // Yalnızca tarama ile gelen fişte; null/atlanırsa sunucu mevcut değeri korur (PUT motoru silmez).
    if (ocrEngine != null) 'ocr_engine': ocrEngine,
    // Dijital faturada ETTN / VKN_FaturaNo; yoksa gönderilmez (PUT mevcut değeri korur).
    if (documentNo != null) 'document_no': documentNo,
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
                  suggestedCategoryId: i.suggestedCategoryId,
                ),
              )
              .toList();
    // İndirim ayrı saklanmaz: kayıtlı tutar kalem toplamından küçükse fark indirimdir.
    final gross = items.fold<double>(0, (s, i) => s + i.amount);
    final diff = ((gross - e.amount) * 100).round() / 100;
    return ReceiptDraft(
      id: e.id,
      clientUid: e.clientUid.isEmpty ? null : e.clientUid,
      merchant: e.merchant,
      categoryId: e.categoryId,
      suggestedCategoryId: e.suggestedCategoryId,
      date: e.date,
      note: e.note,
      items: items,
      discount: diff > 0 ? diff : 0,
      recurringDay: e.recurringDay,
      recurringRemind: e.recurringRemind,
      recurringKind: e.recurringKind,
      recurringEstimate: e.recurringEstimate,
      ocrEngine: e.ocrEngine,
      documentNo: e.documentNo,
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

  ParsedReceipt copyWith({bool? needsReview}) => ParsedReceipt(
    merchant: merchant,
    amount: amount,
    date: date,
    categoryId: categoryId,
    categoryName: categoryName,
    items: items,
    needsManual: needsManual,
    needsReview: needsReview ?? this.needsReview,
    itemsTotal: itemsTotal,
    discountTotal: discountTotal,
    categorySource: categorySource,
    categoryNeedsReview: categoryNeedsReview,
    categoryCandidates: categoryCandidates,
  );

  factory ParsedReceipt.fromJson(Map<String, dynamic> j) => ParsedReceipt(
    merchant: (j['merchant'] as String?) ?? '',
    amount: (j['amount'] as num?)?.toDouble(),
    date: j['date'] is String ? DateTime.tryParse(j['date'] as String) : null,
    categoryId: (j['category_id'] as int?) ?? 0,
    categoryName: (j['category_name'] as String?) ?? kOtherCategory,
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
