import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models.dart';

/// Bir hesabın cihazdaki verisi. Yalnızca sunucuya yüklenmemiş kayıtlar ([SyncState.pending] ve
/// [SyncState.localOnly]) fişlerde tutulur; profillerde sunucudan gelenlerin önbelleği de bulunur
/// (çevrimdışı açılışta profil seçimi çalışsın diye), kategoriler de çevrimdışı fiş girişi içindir.
class LocalSnapshot {
  List<Profile> profiles;
  List<Expense> expenses;
  List<Category> categories;

  /// Cihazdaki fişlere verilen negatif kimlik sayacı (sunucu kimlikleriyle çakışmasın).
  int lastLocalId;

  LocalSnapshot({
    List<Profile>? profiles,
    List<Expense>? expenses,
    List<Category>? categories,
    this.lastLocalId = 0,
  }) : profiles = profiles ?? [],
       expenses = expenses ?? [],
       categories = categories ?? [];

  int nextLocalId() => --lastLocalId;

  factory LocalSnapshot.fromJson(Map<String, dynamic> j) => LocalSnapshot(
    profiles: ((j['profiles'] as List?) ?? [])
        .map((e) => Profile.fromLocalJson(e as Map<String, dynamic>))
        .toList(),
    expenses: ((j['expenses'] as List?) ?? [])
        .map((e) => Expense.fromLocalJson(e as Map<String, dynamic>))
        .toList(),
    categories: ((j['categories'] as List?) ?? [])
        .map((e) => Category.fromJson(e as Map<String, dynamic>))
        .toList(),
    lastLocalId: (j['last_local_id'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'profiles': profiles.map((p) => p.toLocalJson()).toList(),
    'expenses': expenses.map((e) => e.toLocalJson()).toList(),
    'categories': categories.map((c) => {'id': c.id, 'name': c.name}).toList(),
    'last_local_id': lastLocalId,
  };
}

/// Cihazdaki kullanıcı verisi deposu (hesap başına ayrı; testlerde bellek içi sahtesi verilir).
abstract class LocalStore {
  Future<LocalSnapshot> load(int userId);
  Future<void> save(int userId, LocalSnapshot snapshot);

  /// Fotoğrafı cihaza yazar; geri dönen yol fişin `localImages` alanında saklanır.
  Future<String> saveImage(int userId, Uint8List bytes);
  Future<Uint8List?> readImage(String path);
  Future<void> deleteImage(String path);

  /// Hesabın tüm yerel verisini (fişler, profiller, fotoğraflar) kalıcı siler (hesap silme).
  Future<void> deleteAll(int userId);
}

class MemoryLocalStore implements LocalStore {
  final Map<int, String> _data = {};
  final Map<String, Uint8List> _images = {};
  int _n = 0;

  /// Test erişimi.
  Map<String, Uint8List> get images => _images;
  bool hasData(int userId) => _data.containsKey(userId);

  @override
  Future<LocalSnapshot> load(int userId) async {
    final raw = _data[userId];
    if (raw == null) return LocalSnapshot();
    return LocalSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> save(int userId, LocalSnapshot snapshot) async {
    _data[userId] = jsonEncode(snapshot.toJson());
  }

  @override
  Future<String> saveImage(int userId, Uint8List bytes) async {
    final p = 'mem://$userId/${++_n}';
    _images[p] = Uint8List.fromList(bytes);
    return p;
  }

  @override
  Future<Uint8List?> readImage(String path) async => _images[path];

  @override
  Future<void> deleteImage(String path) async => _images.remove(path);

  @override
  Future<void> deleteAll(int userId) async {
    _data.remove(userId);
    _images.removeWhere((k, _) => k.startsWith('mem://$userId/'));
  }
}

/// `<uygulama belgeleri>/fissio/user_<id>/data.json` + `images/`. Yazma önce geçici dosyaya, sonra
/// yeniden adlandırmayla yapılır (yarım yazılmış dosya veriyi bozmasın).
class FileLocalStore implements LocalStore {
  FileLocalStore({Future<Directory> Function()? baseDir})
    : _baseDir = baseDir ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _baseDir;
  int _n = 0;

  Future<Directory> _userDir(int userId) async {
    final base = await _baseDir();
    final d = Directory('${base.path}${Platform.pathSeparator}fissio${Platform.pathSeparator}user_$userId');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  @override
  Future<LocalSnapshot> load(int userId) async {
    try {
      final f = File('${(await _userDir(userId)).path}${Platform.pathSeparator}data.json');
      if (!await f.exists()) return LocalSnapshot();
      return LocalSnapshot.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      // Bozuk dosya uygulamayı açılmaz hale getirmesin; kullanıcı verisi yedekten geri yüklenebilir.
      return LocalSnapshot();
    }
  }

  @override
  Future<void> save(int userId, LocalSnapshot snapshot) async {
    final dir = await _userDir(userId);
    final tmp = File('${dir.path}${Platform.pathSeparator}data.json.tmp');
    await tmp.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    await tmp.rename('${dir.path}${Platform.pathSeparator}data.json');
  }

  @override
  Future<String> saveImage(int userId, Uint8List bytes) async {
    final dir = Directory('${(await _userDir(userId)).path}${Platform.pathSeparator}images');
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}img_${DateTime.now().microsecondsSinceEpoch}_${++_n}.jpg');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  @override
  Future<Uint8List?> readImage(String path) async {
    try {
      final f = File(path);
      return await f.exists() ? await f.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> deleteImage(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  @override
  Future<void> deleteAll(int userId) async {
    try {
      final base = await _baseDir();
      final d = Directory('${base.path}${Platform.pathSeparator}fissio${Platform.pathSeparator}user_$userId');
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}
