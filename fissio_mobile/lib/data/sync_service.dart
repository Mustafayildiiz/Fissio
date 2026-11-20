import 'dart:typed_data';

import '../api.dart';
import '../models.dart';
import 'local_store.dart';

enum FlushOutcome {
  /// Bulut senkronu kapalı: hiçbir şey sunucuya gönderilmez.
  disabled,

  /// Başka bir flush sürüyor.
  busy,

  /// Yüklenecek bekleyen kayıt yok.
  nothing,

  /// Ağ hatası: kayıtlar korundu, bağlantı gelince yeniden denenir.
  offline,

  /// Hepsi yüklendi.
  done,

  /// Bir kısmı yüklenemedi (ağ dışı hata); kalanlar kuyrukta.
  partial,
}

/// Çevrimdışı kuyruğu (senkron AÇIKken yüklenemeyen kayıtlar: [SyncState.pending]) buluta boşaltır.
/// Kurallar:
///  * Senkron KAPALIYKEN hiçbir şey gönderilmez; [SyncState.localOnly] kayıtlara hiçbir koşulda dokunulmaz.
///  * Her kayıt `client_uid` ile idempotent yüklenir (profil: `/profiles`, fiş: `/expenses/bulk`,
///    fotoğraf: fiş oluştuktan sonra); yarıda kesilirse tekrar denemede mükerrer oluşmaz.
///  * Başarılı olan yerelden silinir; ağ hatasında kalanlar korunur.
class SyncService {
  SyncService({
    required this.api,
    required this.local,
    required this.userId,
    required this.enabled,
    required this.snapshot,
    this.onChanged,
  });

  final ApiClient api;
  final LocalStore local;
  final int? Function() userId;
  final bool Function() enabled;
  final LocalSnapshot Function() snapshot;
  final void Function()? onChanged;

  bool _flushing = false;
  bool _rerun = false;
  bool get flushing => _flushing;

  /// Son çalışmada en az bir kayıt/değişiklik buluta ulaştı mı (hiç ilerleme yoksa yeniden indirmeye gerek yok).
  bool progressed = false;

  /// Fotoğraf yüklemesi bu kadar kez (ağ dışı hatayla) başarısız olursa fişin kendisi sunucuda kayıtlı kalır ve
  /// yalnızca yerel fotoğraflar bırakılır; kalıcı reddedilen bir fotoğraf kuyruğu sonsuza dek tutmasın.
  static const maxImageFailures = 5;

  /// Gönderilemeyen (sunucu reddi/hata) kayıt sayısı: kuyruktaki fişler ve bekleyen düzenlemeler (çakışmalar hariç,
  /// bkz. [conflictedEditCount]).
  int get failedCount {
    final s = snapshot();
    return s.expenses.where((e) => e.syncFailures > 0).length +
        s.pendingEdits.where((e) => e.syncFailures > 0 && !e.isEditConflict).length;
  }

  /// Sunucudaki daha yeni sürümle çakışan (409) çevrimdışı düzenlemeler: kullanıcı çözene kadar gönderilmez ve
  /// "iş" sayılmaz (aksi halde her başarılı istek yeni bir boş flush + yenileme döngüsü tetiklerdi).
  int get conflictedEditCount => snapshot().pendingEdits.where((e) => e.isEditConflict).length;

  int get pendingCount {
    final s = snapshot();
    return s.expenses.where((e) => e.syncState == SyncState.pending).length +
        s.profiles.where((p) => p.state == SyncState.pending).length;
  }

  /// Yüklenmeyi bekleyen yerel avatarlar (profil sunucuda var, cihazda avatar dosyası var).
  int get pendingAvatarCount =>
      snapshot().profiles.where((p) => p.localAvatarPath != null && p.serverId != null).length;

  /// Yüklenmeyi bekleyen bütçe limitleri.
  int get pendingBudgetCount => snapshot().budgets.where((b) => b.state == SyncState.pending).length;

  /// Çevrimdışı yapılmış (gönderilecek) düzenleme / fiş silme / limit silme sayısı; çakışmış düzenlemeler hariç.
  int get pendingChangeCount {
    final s = snapshot();
    return s.pendingEdits.where((e) => !e.isEditConflict).length + s.pendingDeletes.length + s.pendingBudgetDeletes.length;
  }

  /// Kuyrukta (fiş/profil/avatar/bütçe/düzenleme/silme) gönderilecek bir şey var mı?
  bool get hasWork =>
      pendingCount > 0 || pendingAvatarCount > 0 || pendingBudgetCount > 0 || pendingChangeCount > 0;

  /// [uid] = bu çalışmanın başladığı hesap: arada hesap değiştiyse başka hesabın verisi yazılmasın.
  Future<void> _persist(int? uid) async {
    final id = userId();
    if (id != null && id == uid) await local.save(id, snapshot());
  }

  Future<FlushOutcome> flush() async {
    if (!enabled()) return FlushOutcome.disabled;
    if (_flushing) {
      // Çalışan flush bağlantı yokken başlamış olabilir; yeni tetikleme kaybolmasın: bitince bir kez daha dene.
      _rerun = true;
      return FlushOutcome.busy;
    }
    if (userId() == null || !hasWork) return FlushOutcome.nothing;
    _flushing = true;
    var outcome = FlushOutcome.done;
    try {
      outcome = await _run();
    } on ApiException catch (e) {
      outcome = e.network ? FlushOutcome.offline : FlushOutcome.partial;
    } finally {
      _flushing = false;
      onChanged?.call();
    }
    if (_rerun) {
      // Çalışırken gelen yeni tetikleme (yeni kuyruğa alınan kayıt vb.) sonuç ne olursa olsun kaybolmasın.
      _rerun = false;
      if (outcome != FlushOutcome.disabled) {
        final again = await flush();
        // İkinci tur yapacak iş bulamadıysa (nothing) ya da meşgulse ilk turun sonucu geçerlidir: aksi halde
        // "done" kaybolur ve çağıran (flushNow) sunucudan yeniden yüklemeyi atlar.
        return again == FlushOutcome.nothing || again == FlushOutcome.busy ? outcome : again;
      }
    }
    return outcome;
  }

  Future<FlushOutcome> _run() async {
    final snap = snapshot();
    var partial = false;
    progressed = false;
    // Çalışma boyunca hesap/senkron durumu değişirse (çıkış, başka hesapla giriş, senkronu kapatma) kalan çağrılar
    // yeni hesabın token'ıyla gitmesin: her ağ adımından önce kontrol edilir.
    final uid = userId();
    bool stale() => userId() != uid || !enabled();

    // 1) Profiller: sunucuda yoksa oluştur (client_uid idempotent).
    for (final p in List<Profile>.of(snap.profiles)) {
      if (p.state != SyncState.pending) continue;
      if (stale()) return FlushOutcome.disabled;
      try {
        final sp = await api.createProfile(p.name, clientUid: p.id);
        final i = snap.profiles.indexWhere((x) => x.id == p.id);
        if (i >= 0) snap.profiles[i] = p.copyWith(serverId: sp.serverId, state: SyncState.synced);
        progressed = true;
        await _persist(uid);
      } on ApiException catch (e) {
        if (e.network) rethrow;
        partial = true; // örn. profil sınırı; fişler bu profile bağlıysa atlanır
      }
    }

    // 1b) Avatarlar: cihazda bekleyen profil fotoğrafı (senkron kapalıyken/çevrimdışıyken seçilmiş) yüklenir.
    for (final p in List<Profile>.of(snap.profiles)) {
      final path = p.localAvatarPath;
      if (path == null || p.serverId == null) continue;
      if (stale()) return FlushOutcome.disabled;
      final bytes = await local.readImage(path);
      try {
        final version = bytes == null ? p.avatarVersion : await api.uploadAvatar(p.serverId!, bytes);
        final i = snap.profiles.indexWhere((x) => x.id == p.id);
        if (i >= 0) snap.profiles[i] = p.copyWith(avatarVersion: version, clearLocalAvatar: true);
        await local.deleteImage(path);
        progressed = true;
        await _persist(uid);
        onChanged?.call();
      } on ApiException catch (e) {
        if (e.network) rethrow;
        partial = true;
      }
    }

    // 2) Fişler: profil başına toplu, idempotent kayıt (≤500). Bir kayıt başarısız olursa (sunucu reddi, 5xx, görsel
    // yükleme hatası) yalnızca o kayıt kuyrukta kalır ve sayaçlanır; diğerleri ve sonraki adımlar etkilenmez.
    final byProfile = <int, List<Expense>>{};
    for (final e in snap.expenses.where((e) => e.syncState == SyncState.pending)) {
      final serverId = snap.profiles.where((p) => p.id == e.profileUid).firstOrNull?.serverId ?? e.profileServerId;
      if (serverId == null) {
        partial = true;
        continue;
      }
      byProfile.putIfAbsent(serverId, () => []).add(e);
    }
    var otherId = snap.categories.where((c) => c.name == kOtherCategory).firstOrNull?.id;
    if (otherId == null && snap.expenses.any((e) => e.syncState == SyncState.pending && e.categoryId <= 0)) {
      // Kategori önbelleği boşken (çevrimdışı ilk kullanım) kategorisiz fiş `category_id: null` ile reddedilirdi:
      // önce sunucudan kategorileri al.
      try {
        final cats = await api.categories();
        if (stale()) return FlushOutcome.disabled;
        snap.categories = cats;
        otherId = cats.where((c) => c.name == kOtherCategory).firstOrNull?.id;
      } on ApiException catch (x) {
        if (x.network) rethrow;
      }
    }
    for (final entry in byProfile.entries) {
      for (var i = 0; i < entry.value.length; i += 500) {
        if (stale()) return FlushOutcome.disabled;
        final batch = entry.value.sublist(i, i + 500 > entry.value.length ? entry.value.length : i + 500);
        // Kayıt başına tüm data.json'u yazmak yerine başarılar parti sonunda (ya da hata/iptalde finally ile) tek seferde
        // diske yazılır: yarıda kesilirse kayıtlar idempotent client_uid ile yeniden gönderilip "skipped" olarak temizlenir.
        var dirty = false;
        try {
          for (final res in await _sendBatch(entry.key, batch, otherId)) {
            if (stale()) return FlushOutcome.disabled;
            final e = res.expense;
            final r = res.result;
            if (!r.ok || r.id == null) {
              partial = true; // geçersiz/reddedilen kayıt: kuyrukta kalır (kullanıcı düzenleyebilir ya da silebilir)
              _bump(
                snap.expenses,
                e.clientUid,
                r.error == 'duplicate_document'
                    ? 'Bu dijital fatura hesabında zaten ekli; bu kaydı silebilirsin.'
                    : (r.error ?? 'Sunucu kaydı kabul etmedi.'),
              );
              await _persist(uid);
              onChanged?.call();
              continue;
            }
            try {
              if (r.status == 'skipped') {
                // Fiş sunucuda zaten var (önceki deneme yanıtı kaybolmuş olabilir). Kullanıcı o arada yerel kopyayı
                // düzenlediyse içerik farklıdır: yerel kopyayı silmeden önce sunucuya yansıt (düzenleme kaybolmasın).
                await _reconcileSkipped(e, r.id!, otherId);
              }
              await _finishImages(e, r.id!, created: r.status == 'created');
            } on ApiException catch (x) {
              if (x.network) rethrow;
              partial = true;
              final failures = _bump(snap.expenses, e.clientUid, x.message);
              if (failures < maxImageFailures) {
                await _persist(uid);
                onChanged?.call();
                continue; // fiş kuyrukta kalır; sonraki çalışmada (idempotent) yeniden denenir
              }
              // Vazgeç: fiş sunucuda kayıtlı; kalıcı reddedilen fotoğraflar yerelden atılır.
              for (final p in e.localImages) {
                await local.deleteImage(p);
              }
            }
            // Sunucudaki kopyayı hemen önbelleğe ekle: kuyruktan çıkan fiş, refresh gelene (ya da başarısız olursa) kadar
            // listelerden ve açık detay sayfasından kaybolmasın. Fotoğraf yüklendiyse sunucudan taze kopya alınır (imageIds).
            var serverCopy = e.copyWith(id: r.id!, syncState: SyncState.synced, localImages: const [], clearSyncError: true);
            if (e.localImages.isNotEmpty) {
              try {
                serverCopy = (await api.expense(r.id!)).copyWith(profileUid: e.profileUid, syncState: SyncState.synced);
              } on ApiException catch (x) {
                if (x.network) rethrow;
              }
            }
            snap.cloudExpenses = [...snap.cloudExpenses.where((x) => x.id != r.id && x.clientUid != e.clientUid), serverCopy];
            snap.expenses.removeWhere((x) => x.clientUid == e.clientUid);
            progressed = true;
            dirty = true;
            onChanged?.call();
          }
        } finally {
          if (dirty) await _persist(uid);
        }
      }
    }

    // 2b) Sunucudaki fişlerin çevrimdışı düzenlemeleri (PUT) ve silmeleri (DELETE). Fiş sunucuda yoksa (404)
    // kayıt sessizce düşer; ağ hatasında kuyrukta kalır. Düzenleme, dayandığı sunucu sürümüyle (`base_updated_at` =
    // kuyruğa alınırken önbellekteki `updated_at`) gönderilir: fiş o arada başka yerde değiştiyse sunucu 409 döner ve
    // düzenleme sessizce üstüne yazılmaz; çakışma olarak işaretlenir, kullanıcı çözene kadar yeniden denenmez.
    for (final e in List<Expense>.of(snap.pendingEdits)) {
      if (e.isEditConflict) continue;
      if (stale()) return FlushOutcome.disabled;
      try {
        final body = bulkBody(e, otherId)..remove('client_uid');
        if (e.updatedAt != null) body['base_updated_at'] = e.updatedAt;
        final saved = await api.updateExpense(e.id, body);
        _upsertCloud(snap, saved, e.profileUid);
        if (e.localImages.isNotEmpty) {
          // İçerik yazıldı; fotoğraf yüklemesi yarıda kalırsa tekrar denemede kendi PUT'umuzla çakışmasın: düzenlemenin
          // dayandığı sürüm artık az önce yazılan sürümdür.
          final i = snap.pendingEdits.indexWhere((y) => y.id == e.id);
          if (i >= 0) snap.pendingEdits[i] = snap.pendingEdits[i].copyWith(updatedAt: saved.updatedAt);
          await _persist(uid);
          final bytes = <Uint8List>[];
          for (final p in e.localImages) {
            final b = await local.readImage(p);
            if (b != null) bytes.add(b);
          }
          if (bytes.isNotEmpty) await api.uploadImages(e.id, bytes);
          for (final p in e.localImages) {
            await local.deleteImage(p);
          }
        }
        snap.pendingEdits.removeWhere((x) => x.id == e.id);
        progressed = true;
        await _persist(uid);
        onChanged?.call();
      } on ApiException catch (x) {
        if (x.network) rethrow;
        if (x.status == 404) {
          snap.pendingEdits.removeWhere((y) => y.id == e.id);
          await _persist(uid);
        } else if (x.conflict) {
          // Kullanıcının düzenlemesi korunur (görünümde o kalır), önbellek sunucudaki güncel kopyayla değişir.
          partial = true;
          if (x.current != null) _upsertCloud(snap, x.current!, e.profileUid);
          final i = snap.pendingEdits.indexWhere((y) => y.id == e.id);
          if (i >= 0) snap.pendingEdits[i] = snap.pendingEdits[i].copyWith(syncError: kEditConflict);
          await _persist(uid);
          onChanged?.call();
        } else {
          partial = true;
          _bumpEdit(snap.pendingEdits, e.id, x.message);
          await _persist(uid);
        }
      }
    }
    for (final id in List<int>.of(snap.pendingDeletes)) {
      if (stale()) return FlushOutcome.disabled;
      try {
        await api.deleteExpense(id);
      } on ApiException catch (x) {
        if (x.network) rethrow;
        if (x.status != 404) {
          partial = true;
          continue;
        }
      }
      snap.pendingDeletes.remove(id);
      snap.cloudExpenses.removeWhere((x) => x.id == id);
      progressed = true;
      await _persist(uid);
      onChanged?.call();
    }

    // 3) Bütçe limitleri: profil sunucuda varsa (profil + kategori başına tek limit; PUT idempotent).
    for (final b in List<Budget>.of(snap.budgets)) {
      if (b.state != SyncState.pending) continue;
      if (stale()) return FlushOutcome.disabled;
      final serverId = snap.profiles.where((p) => p.id == b.profileUid).firstOrNull?.serverId;
      if (serverId == null) {
        partial = true;
        continue;
      }
      try {
        final j = await api.putBudget(serverId, b.categoryId, b.limit);
        final i = snap.budgets.indexWhere((x) => x.profileUid == b.profileUid && x.categoryId == b.categoryId);
        if (i >= 0) {
          snap.budgets[i] = b.copyWith(serverId: (j['id'] as num?)?.toInt(), state: SyncState.synced);
        }
        progressed = true;
        await _persist(uid);
        onChanged?.call();
      } on ApiException catch (e) {
        if (e.network) rethrow;
        partial = true;
      }
    }
    // 4) Çevrimdışıyken silinen limitler (sunucu kimliğiyle; 404 = zaten yok).
    for (final id in List<int>.of(snap.pendingBudgetDeletes)) {
      if (stale()) return FlushOutcome.disabled;
      try {
        await api.deleteBudget(id);
      } on ApiException catch (e) {
        if (e.network) rethrow;
        if (e.status != 404) {
          partial = true;
          continue;
        }
      }
      snap.pendingBudgetDeletes.remove(id);
      progressed = true;
      await _persist(uid);
    }
    return partial ? FlushOutcome.partial : FlushOutcome.done;
  }

  /// Bir profilin fişlerini toplu gönderir. Parti ağ dışı bir hatayla (413/5xx...) reddedilirse kayıtlar TEK TEK
  /// yeniden denenir: bozuk tek kayıt yalnızca kendisini başarısız yapar, diğerleri kuyruktan çıkar. Ağ hatası
  /// (bağlantı yok) olduğu gibi yukarı fırlatılır.
  Future<List<({Expense expense, BulkItemResult result})>> _sendBatch(
    int profileId,
    List<Expense> batch,
    int? otherId,
  ) async {
    try {
      final resp = await api.bulkExpenses([for (final e in batch) bulkBody(e, otherId)], profileId: profileId);
      return [
        for (final r in resp.results)
          if (r.index >= 0 && r.index < batch.length) (expense: batch[r.index], result: r),
      ];
    } on ApiException catch (e) {
      if (e.network) rethrow;
      if (batch.length == 1) {
        return [(expense: batch.first, result: BulkItemResult(0, batch.first.clientUid, 'error', null, e.message))];
      }
      return [for (final x in batch) ...await _sendBatch(profileId, [x], otherId)];
    }
  }

  /// `skipped`: sunucudaki kopya yerel kopyadan farklıysa yerel (daha yeni) hali PUT ile yazar.
  Future<void> _reconcileSkipped(Expense local, int serverId, int? otherId) async {
    final server = await api.expense(serverId);
    if (!sameContent(local, server, otherId)) {
      await api.updateExpense(serverId, bulkBody(local, otherId)..remove('client_uid'));
    }
  }

  /// Yerel ve sunucu fişinin kullanıcı tarafından düzenlenebilen alanları aynı mı?
  static bool sameContent(Expense l, Expense s, int? otherId) {
    bool near(double a, double b) => (a - b).abs() < 0.005;
    final cat = l.categoryId > 0 ? l.categoryId : (otherId ?? 0);
    if (l.merchant != s.merchant || !near(l.amount, s.amount) || l.note != s.note || cat != s.categoryId) return false;
    if (l.date.year != s.date.year || l.date.month != s.date.month || l.date.day != s.date.day) return false;
    if (l.items.length != s.items.length) return false;
    for (var i = 0; i < l.items.length; i++) {
      final a = l.items[i], b = s.items[i];
      if (a.name != b.name || !near(a.amount, b.amount) || (a.categoryId ?? 0) != (b.categoryId ?? 0)) return false;
    }
    if (l.recurringDay != s.recurringDay) return false;
    if (l.recurringDay > 0) {
      if (l.recurringRemind != s.recurringRemind || l.recurringKind != s.recurringKind) return false;
      if (l.recurringKind == RecurringKind.variable && !near(l.recurringEstimate, s.recurringEstimate)) return false;
    }
    return true;
  }

  /// Sunucudan gelen fiş kopyasını önbelleğe yazar (kimliğe göre değiştirir ya da ekler); profil istemci kimliği
  /// sunucu profil kimliğinden, bilinmiyorsa önbellekteki eski kopyadan / [fallbackProfileUid]'den gelir.
  static void _upsertCloud(LocalSnapshot snap, Expense server, String fallbackProfileUid) {
    final i = snap.cloudExpenses.indexWhere((x) => x.id == server.id);
    final profileUid = snap.profiles.where((p) => p.serverId != null && p.serverId == server.profileServerId).firstOrNull?.id ??
        (i >= 0 ? snap.cloudExpenses[i].profileUid : fallbackProfileUid);
    final copy = server.copyWith(profileUid: profileUid, syncState: SyncState.synced);
    if (i >= 0) {
      snap.cloudExpenses[i] = copy;
    } else {
      snap.cloudExpenses = [...snap.cloudExpenses, copy];
    }
  }

  /// Kuyruktaki fişin başarısızlık sayacını artırır; yeni sayıyı döndürür.
  int _bump(List<Expense> list, String clientUid, String message) {
    final i = list.indexWhere((x) => x.clientUid == clientUid);
    if (i < 0) return 0;
    final n = list[i].syncFailures + 1;
    list[i] = list[i].copyWith(syncFailures: n, syncError: message);
    return n;
  }

  void _bumpEdit(List<Expense> list, int id, String message) {
    final i = list.indexWhere((x) => x.id == id);
    if (i >= 0) list[i] = list[i].copyWith(syncFailures: list[i].syncFailures + 1, syncError: message);
  }

  /// Fiş sunucuda var: yerel fotoğrafları yükle (sunucuda hiç görsel yoksa) ve yerel dosyaları sil.
  Future<void> _finishImages(Expense e, int serverId, {required bool created}) async {
    if (e.localImages.isEmpty) return;
    var upload = created;
    if (!upload) {
      // Önceki bir denemede fiş oluştu ama görsel yüklemesi yarıda kaldıysa görseller tekrar yüklenir;
      // zaten yüklenmişse (yükleme tek işlemdir) tekrarlanmaz.
      upload = (await api.expense(serverId)).imageIds.isEmpty;
    }
    if (upload) {
      final bytes = <Uint8List>[];
      for (final p in e.localImages) {
        final b = await local.readImage(p);
        if (b != null) bytes.add(b);
      }
      if (bytes.isNotEmpty) await api.uploadImages(serverId, bytes);
    }
    for (final p in e.localImages) {
      await local.deleteImage(p);
    }
  }

  /// `POST /expenses/bulk` gövdesindeki tek fiş.
  static Map<String, dynamic> bulkBody(Expense e, int? otherCategoryId) => {
    'client_uid': e.clientUid,
    'merchant': e.merchant,
    'amount': e.amount,
    'date': '${e.date.year.toString().padLeft(4, '0')}-${e.date.month.toString().padLeft(2, '0')}-${e.date.day.toString().padLeft(2, '0')}',
    'category_id': e.categoryId > 0 ? e.categoryId : otherCategoryId,
    if (e.suggestedCategoryId != null) 'suggested_category_id': e.suggestedCategoryId,
    'note': e.note,
    'items': e.items.map((i) => i.toJson()).toList(),
    // Çevrimdışı kuyrukta girilen "Her ay tekrarlanır" işareti sunucuya da taşınır.
    'recurring_day': e.recurringDay,
    'recurring_remind': e.recurringRemind,
    'recurring_kind': e.recurringKind.name,
    if (e.recurringDay > 0 && e.recurringKind == RecurringKind.variable && e.recurringEstimate > 0)
      'recurring_estimate': e.recurringEstimate,
    // Fişi okuyan OCR motoru (yalnızca bilgi); null ise gönderilmez, sunucudaki değer korunur.
    if (e.ocrEngine != null) 'ocr_engine': e.ocrEngine,
    // Dijital fatura kimliği (ETTN / VKN_FaturaNo): sunucu mükerrer eklemeyi 409 ile engeller.
    if (e.documentNo != null) 'document_no': e.documentNo,
  };
}
