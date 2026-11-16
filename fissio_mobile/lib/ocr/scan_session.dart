import 'dart:typed_data';

/// Çok fotoğraflı (uzun fiş) çekim oturumu: sayfa listesi, limit ve sıralama.
/// Saf Dart; arayüzden bağımsız olduğu için birim test edilebilir.
class ScanSession {
  ScanSession({List<Uint8List>? initial}) {
    if (initial != null) addAll(initial);
  }

  /// Sunucunun tek taramada kabul ettiği en fazla sayfa (`maxScanPages`).
  static const int maxPages = 6;

  final List<Uint8List> _pages = [];

  List<Uint8List> get pages => List.unmodifiable(_pages);
  int get length => _pages.length;
  bool get isEmpty => _pages.isEmpty;
  bool get isFull => _pages.length >= maxPages;
  int get remaining => maxPages - _pages.length;

  /// Boş olmayan bir sayfa ekler; limit doluysa veya veri boşsa false döner.
  bool add(Uint8List page) {
    if (page.isEmpty || isFull) return false;
    _pages.add(page);
    return true;
  }

  /// Sırayla ekler, limit dolunca kalanını yok sayar; eklenen sayfa sayısını döner.
  int addAll(Iterable<Uint8List> pages) {
    var added = 0;
    for (final p in pages) {
      if (!add(p)) break;
      added++;
    }
    return added;
  }

  void removeAt(int index) {
    if (index < 0 || index >= _pages.length) return;
    _pages.removeAt(index);
  }

  /// `ReorderableListView.onReorderItem` semantiği: [newIndex] öğe çıkarıldıktan SONRAKİ konumdur.
  void move(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _pages.length) return;
    if (newIndex < 0 || newIndex >= _pages.length || newIndex == oldIndex) {
      return;
    }
    _pages.insert(newIndex, _pages.removeAt(oldIndex));
  }

  void clear() => _pages.clear();
}
