// Dijital fiş: platform sipariş kodu (`order_id`) çıkarımı ve ön özet + resmi fatura birleştirme kararı (saf Dart).
// Go ikizi: services/expense/internal/digital/{ids,merge}.go (otorite Go). Ortak vektörler: testdata/digital_ids.json ve
// testdata/merge_decision.json.
import 'normalize.dart' show foldTR;

final RegExp _orderIdValidRe = RegExp(r'^[A-Z0-9][A-Z0-9.-]{3,40}$');
final RegExp _orderLabelRe = RegExp(r'\b(?:siparis|order)\s*(?:(?:numarasi|numaraniz|numara|number|no|nr|kodu|id)\b|#|:)[\s:#.\-–—]*');
final RegExp _orderTokenRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.\-]{3,40}');
final RegExp _trailingDotDash = RegExp(r'[.\-]+$');
final RegExp _hasDigit = RegExp(r'\d');

/// Sipariş numarasını sunucudaki biçime çevirir (büyük harf); geçersizse null.
String? normalizeOrderId(String? raw) {
  if (raw == null) return null;
  final v = raw.trim().toUpperCase();
  return _orderIdValidRe.hasMatch(v) ? v : null;
}

/// Metinden platform sipariş kodunu çıkarır. YALNIZCA etiketli değer kabul edilir ("Sipariş No", "Sipariş Numarası",
/// "Sipariş Kodu", "Order ID/Number/No"…): değer aynı satırda ya da (etiket satırı boşsa) sonraki satırın tamamıdır; en az
/// bir rakam içermelidir (ör. `GPA.3345-1234-5678-12345`). Fatura/ETTN/fiş no asla sipariş no sayılmaz. Yoksa null.
String? extractOrderId(String text) {
  final lines = text.replaceAll('\r', '').split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final m = _orderLabelRe.firstMatch(foldTR(line));
    if (m == null) continue;
    // foldTR karakter başına karakter üretir: konum özgün satıra da uygulanır.
    final rest = m.end >= line.length ? '' : line.substring(m.end).trim();
    if (rest.isNotEmpty) {
      final id = _orderTokenFrom(rest);
      if (id != null) return id;
      continue;
    }
    if (i + 1 < lines.length) {
      final next = lines[i + 1].trim();
      final tok = _orderTokenFrom(next);
      if (tok != null && next.replaceFirst(_trailingDotDash, '').toUpperCase() == tok) return tok;
    }
  }
  return null;
}

String? _orderTokenFrom(String s) {
  final m = _orderTokenRe.firstMatch(s);
  if (m == null) return null;
  final tok = m[0]!.replaceFirst(_trailingDotDash, '');
  if (!_hasDigit.hasMatch(tok)) return null;
  return normalizeOrderId(tok);
}

// ---------------------------------------------------------------------------------------------------------------------
// Birleştirme kararı

/// Birleştirme kararında kullanılan, depodan bağımsız fiş özeti.
class MergeDoc {
  final int id;
  final String merchant;
  final int amountCents;

  /// YYYY-MM-DD ('' = bilinmiyor).
  final String date;

  /// ETTN ya da VKN_FaturaNo ('' = yok).
  final String documentNo;
  final String orderId;
  final List<String> items;

  const MergeDoc({
    this.id = 0,
    this.merchant = '',
    this.amountCents = 0,
    this.date = '',
    this.documentNo = '',
    this.orderId = '',
    this.items = const [],
  });

  /// Kayıt resmi bir E-Arşiv/E-Fatura belgesine dayanıyor mu (`has_official_invoice` türetimi).
  bool get official => documentNo.isNotEmpty;
}

const kMergeCreate = 'create';
const kMergeDuplicate = 'duplicate';
const kMergeMerge = 'merge';

/// Resmi fatura ile ön özet arasındaki en çok gün farkı.
const kMergeWindowDays = 3;

/// İki tarafta da kalem varken katlanmış kalem adı jetonlarının en az Jaccard benzerliği.
const kItemSimilarityMin = 0.5;

class MergeDecision {
  final String action;
  final int targetId;
  const MergeDecision(this.action, [this.targetId = 0]);
  @override
  String toString() => 'MergeDecision($action, $targetId)';
}

/// Gelen belge için kayıt/mükerrer/birleştirme kararı (Go `DecideMerge` ikizi).
///
/// A) Mutlak mükerrer: aynı document_no; ya da aynı order_id + aynı belge türü; ya da ön özet, aynı order_id'li resmi kayıt
///    varken gelirse. B) Gelen RESMİ belge, resmi bağlanmamış (ön özet) TEK adaya birleşir: önce order_id; order_id yoksa aynı
///    işletme + aynı tutar (kuruş) + ±3 gün + kalem benzerliği ve eşleşen aday tam 1 ise. C) Asla: order_id'ler ikisinde de var
///    ve farklı; gelen ön özet; birden fazla aday (belirsizlik).
MergeDecision decideMerge(MergeDoc incoming, List<MergeDoc> candidates) {
  if (incoming.documentNo.isNotEmpty) {
    for (final c in candidates) {
      if (c.documentNo == incoming.documentNo) return MergeDecision(kMergeDuplicate, c.id);
    }
  }
  if (incoming.orderId.isNotEmpty) {
    for (final c in candidates) {
      if (c.orderId != incoming.orderId) continue;
      if (c.official == incoming.official || (!incoming.official && c.official)) {
        return MergeDecision(kMergeDuplicate, c.id);
      }
    }
  }
  if (!incoming.official) return const MergeDecision(kMergeCreate);

  final pool = [for (final c in candidates) if (!c.official) c];
  if (incoming.orderId.isNotEmpty) {
    final byOrder = [for (final c in pool) if (c.orderId == incoming.orderId) c];
    if (byOrder.length == 1) return MergeDecision(kMergeMerge, byOrder.first.id);
    if (byOrder.length > 1) return const MergeDecision(kMergeCreate);
  }
  final matches = <MergeDoc>[];
  for (final c in pool) {
    if (incoming.orderId.isNotEmpty && c.orderId.isNotEmpty && incoming.orderId != c.orderId) continue;
    if (_fuzzyMatch(incoming, c)) matches.add(c);
  }
  if (matches.length == 1) return MergeDecision(kMergeMerge, matches.first.id);
  return const MergeDecision(kMergeCreate);
}

bool _fuzzyMatch(MergeDoc a, MergeDoc b) {
  if (a.amountCents != b.amountCents || a.amountCents <= 0) return false;
  if (!_withinDays(a.date, b.date, kMergeWindowDays)) return false;
  if (!_merchantMatch(a.merchant, b.merchant)) return false;
  final ta = _itemTokens(a.items);
  final tb = _itemTokens(b.items);
  if (ta.isNotEmpty && tb.isNotEmpty && _jaccard(ta, tb) < kItemSimilarityMin) return false;
  return true;
}

final RegExp _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

DateTime? _parseIso(String s) {
  final m = _isoDate.firstMatch(s);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final t = DateTime.utc(y, mo, d);
  return (t.year == y && t.month == mo && t.day == d) ? t : null;
}

bool _withinDays(String a, String b, int n) {
  final ta = _parseIso(a), tb = _parseIso(b);
  if (ta == null || tb == null) return false;
  return ta.difference(tb).inDays.abs() <= n;
}

final RegExp _nonAlnum = RegExp(r'[^\p{L}\p{Nd}]+', unicode: true);

/// Katlanmış, harf/rakam dışı ayraçlı, ≥2 karakterli jetonlar (Go `keyTokens` ikizi).
List<String> _keyTokens(String s) => [
  for (final p in foldTR(s).split(_nonAlnum))
    if (p.runes.length >= 2) p,
];

Set<String> _itemTokens(List<String> items) => {for (final it in items) ..._keyTokens(it)};

double _jaccard(Set<String> a, Set<String> b) {
  final inter = a.where(b.contains).length;
  final union = a.length + b.length - inter;
  return union == 0 ? 0 : inter / union;
}

/// Jeton kümeleri eşit ya da küçük küme büyüğün alt kümesi ve en az bir ≥3 karakterli ortak jeton.
bool _merchantMatch(String a, String b) {
  final sa = _keyTokens(a).toSet(), sb = _keyTokens(b).toSet();
  if (sa.isEmpty || sb.isEmpty) return false;
  final small = sa.length > sb.length ? sb : sa;
  final big = sa.length > sb.length ? sa : sb;
  var long = false;
  for (final t in small) {
    if (!big.contains(t)) return false;
    if (t.runes.length >= 3) long = true;
  }
  return long;
}
