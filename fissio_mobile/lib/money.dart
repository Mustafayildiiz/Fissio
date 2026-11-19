/// Kullanıcı/dosya girdisinden tutar okur (tek kaynak): 12,50 / 12.50 / 1.234,50 / 1,234.50 / "12,50 ₺" / "3000 TL".
/// Son görülen ayraç ondalıktır, diğeri binlik; yalnız noktalı ve `1.234` biçimi binlik sayılır.
/// (OCR satırı için Go ile birebir ikiz olan `receipt_parser/parser.dart` `parseAmount` ayrıdır: o, fiş
/// sütunundaki jetonları okur ve Go `parseAmount` ile aynı kalmak zorundadır.)
double? parseMoney(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'[\s₺]|TL', caseSensitive: false), '');
  if (s.isEmpty) return null;
  final lastComma = s.lastIndexOf(',');
  final lastDot = s.lastIndexOf('.');
  if (lastComma >= 0 && lastDot >= 0) {
    if (lastComma > lastDot) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    } else {
      s = s.replaceAll(',', '');
    }
  } else if (lastComma >= 0) {
    s = s.replaceAll(',', '.');
  } else if (lastDot >= 0 && RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s)) {
    s = s.replaceAll('.', ''); // 1.234 -> binlik
  }
  final v = double.tryParse(s);
  return v == null || v.isNaN || v.isInfinite ? null : v;
}
