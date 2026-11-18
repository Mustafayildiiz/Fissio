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

  /// Çevrimdışı yapılmış düzenleme / fiş silme / limit silme sayısı.
  int get pendingChangeCount {
    final s = snapshot();
    return s.pendingEdits.length + s.pendingDeletes.length + s.pendingBudgetDeletes.length;
  }

  /// Kuyrukta (fiş/profil/avatar/bütçe/düzenleme/silme) gönderilecek bir şey var mı?
  bool get hasWork =>
      pendingCount > 0 || pendingAvatarCount > 0 || pendingBudgetCount > 0 || pendingChangeCount > 0;

  Future<void> _persist() async {
    final id = userId();
    if (id != null) await local.save(id, snapshot());
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
      _rerun = false;
      if (outcome == FlushOutcome.offline || outcome == FlushOutcome.partial) return flush();
    }
    return outcome;
  }

  Future<FlushOutcome> _run() async {
    final snap = snapshot();
    var partial = false;

    // 1) Profiller: sunucuda yoksa oluştur (client_uid idempotent).
    for (final p in List<Profile>.of(snap.profiles)) {
      if (p.state != SyncState.pending) continue;
      if (!enabled()) return FlushOutcome.disabled;
      try {
        final sp = await api.createProfile(p.name, clientUid: p.id);
        final i = snap.profiles.indexWhere((x) => x.id == p.id);
        if (i >= 0) snap.profiles[i] = p.copyWith(serverId: sp.serverId, state: SyncState.synced);
        await _persist();
      } on ApiException catch (e) {
        if (e.network) rethrow;
        partial = true; // örn. profil sınırı; fişler bu profile bağlıysa atlanır
      }
    }

    // 1b) Avatarlar: cihazda bekleyen profil fotoğrafı (senkron kapalıyken/çevrimdışıyken seçilmiş) yüklenir.
    for (final p in List<Profile>.of(snap.profiles)) {
      final path = p.localAvatarPath;
      if (path == null || p.serverId == null) continue;
      if (!enabled()) return FlushOutcome.disabled;
      final bytes = await local.readImage(path);
      try {
        final version = bytes == null ? p.avatarVersion : await api.uploadAvatar(p.serverId!, bytes);
        final i = snap.profiles.indexWhere((x) => x.id == p.id);
        if (i >= 0) snap.profiles[i] = p.copyWith(avatarVersion: version, clearLocalAvatar: true);
        await local.deleteImage(path);
        await _persist();
        onChanged?.call();
      } on ApiException catch (e) {
        if (e.network) rethrow;
        partial = true;
      }
    }

    // 2) Fişler: profil başına toplu, idempotent kayıt (≤500).
    final byProfile = <int, List<Expense>>{};
    for (final e in snap.expenses.where((e) => e.syncState == SyncState.pending)) {
      final serverId = snap.profiles.where((p) => p.id == e.profileUid).firstOrNull?.serverId ?? e.profileServerId;
      if (serverId == null) {
        partial = true;
        continue;
      }
      byProfile.putIfAbsent(serverId, () => []).add(e);
    }
    final otherId = snap.categories.where((c) => c.name == 'Diğer').firstOrNull?.id;
    for (final entry in byProfile.entries) {
      for (var i = 0; i < entry.value.length; i += 500) {
        if (!enabled()) return FlushOutcome.disabled;
        final batch = entry.value.sublist(i, i + 500 > entry.value.length ? entry.value.length : i + 500);
        final resp = await api.bulkExpenses(
          [for (final e in batch) bulkBody(e, otherId)],
          profileId: entry.key,
        );
        for (final r in resp.results) {
          final e = batch[r.index];
          if (!r.ok || r.id == null) {
            partial = true; // geçersiz kayıt: kuyrukta kalır (kullanıcı düzenleyebilir)
            continue;
          }
          await _finishImages(e, r.id!, created: r.status == 'created');
          snap.expenses.removeWhere((x) => x.clientUid == e.clientUid);
          await _persist();
          onChanged?.call();
        }
      }
    }

    // 2b) Sunucudaki fişlerin çevrimdışı düzenlemeleri (PUT) ve silmeleri (DELETE). Fiş sunucuda yoksa (404)
    // kayıt sessizce düşer; ağ hatasında kuyrukta kalır.
    for (final e in List<Expense>.of(snap.pendingEdits)) {
      if (!enabled()) return FlushOutcome.disabled;
      try {
        await api.updateExpense(e.id, bulkBody(e, otherId)..remove('client_uid'));
        if (e.localImages.isNotEmpty) {
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
        await _persist();
        onChanged?.call();
      } on ApiException catch (x) {
        if (x.network) rethrow;
        if (x.status == 404) {
          snap.pendingEdits.removeWhere((y) => y.id == e.id);
          await _persist();
        } else {
          partial = true;
        }
      }
    }
    for (final id in List<int>.of(snap.pendingDeletes)) {
      if (!enabled()) return FlushOutcome.disabled;
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
      await _persist();
      onChanged?.call();
    }

    // 3) Bütçe limitleri: profil sunucuda varsa (profil + kategori başına tek limit; PUT idempotent).
    for (final b in List<Budget>.of(snap.budgets)) {
      if (b.state != SyncState.pending) continue;
      if (!enabled()) return FlushOutcome.disabled;
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
        await _persist();
        onChanged?.call();
      } on ApiException catch (e) {
        if (e.network) rethrow;
        partial = true;
      }
    }
    // 4) Çevrimdışıyken silinen limitler (sunucu kimliğiyle; 404 = zaten yok).
    for (final id in List<int>.of(snap.pendingBudgetDeletes)) {
      if (!enabled()) return FlushOutcome.disabled;
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
      await _persist();
    }
    return partial ? FlushOutcome.partial : FlushOutcome.done;
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
  };
}
