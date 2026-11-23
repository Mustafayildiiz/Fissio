// Dijital fiş / e-fatura (metin katmanlı PDF) ayrıştırma yardımcıları — saf Dart, eklentisiz, sınanabilir.
//
// PDF'ten çıkan metin fiş OCR'ı gibi `parseReceiptText`'e verilir (tarih, işletme, kalemler, toplam). Bu dosya
// ek olarak (1) metin katmanının yeterli olup olmadığını (taranmış PDF → OCR'a düşer), (2) MÜKERRER eklemeyi önleyen
// belge kimliğini (`documentNo`) çıkarır.
//
// documentNo kuralı (sunucu `normalizeDocumentNo` ile aynı): YALNIZCA 36 karakterli standart ETTN UUID'si ya da
// `VKN_FaturaNo` birleşimi. Kısa fiş/sipariş/Z numaraları ("FİŞ NO 0468", "Sipariş Kodu 01D") tek başına başka
// belgelerle çakışırdı; bu yüzden asla kimlik olmaz (kimlik bulunamazsa null → mükerrer denetimi yapılmaz).
import 'normalize.dart' show foldTR;
import 'parser.dart' show amountRe;

final RegExp _ettnRe = RegExp(
  r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
);
final RegExp _documentNoRe = RegExp(
  r'^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9]{10,11}_[A-Z0-9-]{3,32})$',
);

/// Standart e-fatura/e-arşiv numarası: 3 karakter seri + 13 hane (yıl + sıra), örn. `GIB2024000000123`.
final RegExp _invoiceNoRe = RegExp(r'\b[A-Za-z0-9]{3}\d{13}\b');
final RegExp _vknRe = RegExp(r'\b\d{10,11}\b');

/// Belge kimliğini sunucudaki biçime çevirir: ETTN küçük harf, `VKN_FaturaNo` büyük harf. Geçerli değilse null.
String? normalizeDocumentNo(String? raw) {
  if (raw == null) return null;
  var v = raw.trim();
  if (v.isEmpty) return null;
  final i = v.indexOf('_');
  v = i >= 0 ? v.substring(0, i + 1) + v.substring(i + 1).toUpperCase() : v.toLowerCase();
  return _documentNoRe.hasMatch(v) ? v : null;
}

/// Metinden belge kimliğini çıkarır: önce "ETTN" etiketli UUID, yoksa satıcı VKN'si + fatura numarası.
/// Hiçbiri güvenilir biçimde bulunamazsa null.
String? extractDocumentNo(String text) {
  final lines = text.replaceAll('\r', '').split('\n');
  // 1) ETTN: "ETTN" etiketli satırdaki (ya da sonraki satırdaki) UUID; yoksa metindeki ilk UUID.
  for (var i = 0; i < lines.length; i++) {
    if (!foldTR(lines[i]).contains('ettn')) continue;
    for (final l in [lines[i], if (i + 1 < lines.length) lines[i + 1]]) {
      final m = _ettnRe.firstMatch(l);
      if (m != null) return normalizeDocumentNo(m[0]);
    }
  }
  // Etiketsiz UUID kimlik OLMAZ (satıcı/mağaza kimliği gibi her faturada aynı değer çıkabilir ve sonraki faturaların
  // hepsini "zaten eklenmiş" yapardı): ETTN yalnızca "ETTN" etiketli satırda (ya da sonraki satırda) aranır.

  // 2) VKN_FaturaNo: etiketli ilk VKN/TCKN (satıcı belgenin başında olur) + biçimi tutan fatura numarası.
  String? vkn;
  for (final l in lines) {
    final f = foldTR(l);
    if (!(f.contains('vkn') || f.contains('vergi kimlik') || f.contains('tckn') || f.contains('t.c. kimlik'))) continue;
    final m = _vknRe.firstMatch(l);
    if (m != null) {
      vkn = m[0];
      break;
    }
  }
  if (vkn == null) return null;
  for (var i = 0; i < lines.length; i++) {
    final f = foldTR(lines[i]);
    if (!(f.contains('fatura no') || f.contains('fatura numarasi') || f.contains('belge no'))) continue;
    for (final l in [lines[i], if (i + 1 < lines.length) lines[i + 1]]) {
      final m = _invoiceNoRe.firstMatch(l);
      if (m != null) return normalizeDocumentNo('${vkn}_${m[0]}');
    }
  }
  return null;
}

/// PDF'in metin katmanı fiş ayrıştırmaya yetecek kadar dolu mu? Taranmış (görsel) PDF'te metin yoktur ya da
/// yalnızca birkaç karakterdir; o durumda sayfalar görsele çevrilip OCR'a düşer. Ölçüt: en az 40 harf ve bir tutar.
bool hasUsableTextLayer(List<String> pageTexts) {
  final text = pageTexts.join('\n');
  var letters = 0;
  for (final r in text.runes) {
    final s = String.fromCharCode(r);
    if (s.toLowerCase() != s.toUpperCase()) letters++;
  }
  return letters >= 40 && amountRe.hasMatch(text);
}

/// Sayfa metinlerini tek metne birleştirir (fazladan boş satırlar atılır, satır sonları korunur).
String joinPageTexts(List<String> pageTexts) => [
  for (final t in pageTexts)
    if (t.trim().isNotEmpty) t.replaceAll('\r', '').trim(),
].join('\n');
