import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../app_state.dart';
import '../models.dart';
import 'uid.dart';

/// Yedekleme dosyası biçimleri (JSON: tam yedek, CSV: tablo incelemesi) — saf Dart, ağ/disk bilmez.
///
/// JSON: `{format:"fissio-backup", version:1, exported_at, profiles:[{uid,name,expenses:[{uid,date,merchant,
/// amount,category,note,items:[{name,amount,category}]}]}]}`.
/// CSV (UTF-8 BOM, `;` ayraçlı, satır = kalem): profil;profil_uid;fis_uid;tarih;isyeri;toplam;kategori;not;
/// kalem_adi;kalem_tutar;kalem_kategori. Kalemi olmayan fiş için kalem sütunları boş tek satır yazılır.
const backupFormat = 'fissio-backup';
const backupVersion = 1;

const _maxProfiles = 50;
const _maxExpenses = 20000;
const _maxItems = 100;

class BackupItem {
  final String name;
  final double amount;
  final String category;
  const BackupItem(this.name, this.amount, this.category);
}

class BackupExpense {
  /// Boşsa içe aktarma sırasında parmak izinden türetilir.
  final String uid;
  final DateTime date;
  final String merchant;
  final double amount;
  final String category;
  final String note;
  final List<BackupItem> items;
  const BackupExpense({
    required this.uid,
    required this.date,
    required this.merchant,
    required this.amount,
    required this.category,
    required this.note,
    required this.items,
  });
}

class BackupProfile {
  final String uid;
  final String name;
  final List<BackupExpense> expenses;
  const BackupProfile(this.uid, this.name, this.expenses);
}

class BackupData {
  final int version;
  final DateTime? exportedAt;
  final List<BackupProfile> profiles;

  /// Dosyada okunamayan/geçersiz kayıtlar (satır/fiş numarasıyla); geçerli olanlar yine içe aktarılır.
  final List<String> errors;
  const BackupData(this.version, this.exportedAt, this.profiles, [this.errors = const []]);
  int get expenseCount => profiles.fold(0, (s, p) => s + p.expenses.length);
}

class ImportSummary {
  final int imported;
  final int skipped;
  final int profilesCreated;
  final List<String> errors;
  const ImportSummary(this.imported, this.skipped, this.profilesCreated, this.errors);
}

// ---------------------------------------------------------------- yardımcılar

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 12,50 / 12.50 / 1.234,50 / 1,234.50 / "12,50 ₺" biçimlerini okur.
double? parseAmount(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'[\s₺]|TL', caseSensitive: false), '');
  if (s.isEmpty) return null;
  final lastComma = s.lastIndexOf(',');
  final lastDot = s.lastIndexOf('.');
  if (lastComma >= 0 && lastDot >= 0) {
    // Son görülen ayraç ondalıktır, diğeri binlik.
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

DateTime? parseDate(String raw) {
  final s = raw.trim();
  var m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(s);
  int y, mo, d;
  if (m != null) {
    y = int.parse(m[1]!);
    mo = int.parse(m[2]!);
    d = int.parse(m[3]!);
  } else {
    m = RegExp(r'^(\d{1,2})[./](\d{1,2})[./](\d{4})$').firstMatch(s);
    if (m == null) return null;
    d = int.parse(m[1]!);
    mo = int.parse(m[2]!);
    y = int.parse(m[3]!);
  }
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || y < 1990 || y > 2100) return null;
  final dt = DateTime(y, mo, d);
  return dt.month == mo ? dt : null; // 31 Şubat gibi taşmaları reddet
}

String _clip(String s, int n) {
  final r = s.trim().runes.toList();
  return r.length <= n ? s.trim() : String.fromCharCodes(r.take(n));
}

String _fmtAmount(double v) => v.toStringAsFixed(2);

/// Aynı fişin kimliği (uid yoksa/uyuşmazsa mükerrer tespiti): profil adı, tarih, işyeri, tutar ve kalemler.
String fingerprint(String profileName, DateTime date, String merchant, double amount, List<BackupItem> items) {
  final b = StringBuffer()
    ..write(profileName.trim().toLowerCase())
    ..write('|')
    ..write(_iso(date))
    ..write('|')
    ..write(merchant.trim().toLowerCase())
    ..write('|')
    ..write(_fmtAmount(amount));
  for (final i in items) {
    b
      ..write('|')
      ..write(i.name.trim().toLowerCase())
      ..write('=')
      ..write(_fmtAmount(i.amount));
  }
  return sha256.convert(utf8.encode(b.toString())).toString();
}

String uidFromFingerprint(String fp) => 'fp-${fp.substring(0, 24)}';

// ---------------------------------------------------------------- dışa aktarma

/// [profileId] verilirse yalnızca o profil, yoksa tüm hesap. Fişler tarihe göre (eskiden yeniye) sıralanır.
BackupData buildBackup(
  List<Profile> profiles,
  List<Expense> expenses, {
  String? profileId,
  DateTime? now,
}) {
  final out = <BackupProfile>[];
  for (final p in profiles) {
    if (profileId != null && p.id != profileId) continue;
    final list = expenses.where((e) => e.profileUid == p.id).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    out.add(
      BackupProfile(p.id, p.name, [
        for (final e in list)
          BackupExpense(
            uid: e.clientUid.isNotEmpty
                ? e.clientUid
                : uidFromFingerprint(fingerprint(p.name, e.date, e.merchant, e.amount, [
                    for (final i in e.items) BackupItem(i.name, i.amount, i.categoryName ?? ''),
                  ])),
            date: e.date,
            merchant: e.merchant,
            amount: e.amount,
            category: e.categoryName,
            note: e.note,
            items: [for (final i in e.items) BackupItem(i.name, i.amount, i.categoryName ?? '')],
          ),
      ]),
    );
  }
  return BackupData(backupVersion, now ?? DateTime.now().toUtc(), out);
}

String exportJson(BackupData b) => const JsonEncoder.withIndent('  ').convert({
  'format': backupFormat,
  'version': backupVersion,
  'exported_at': (b.exportedAt ?? DateTime.now()).toUtc().toIso8601String(),
  'profiles': [
    for (final p in b.profiles)
      {
        'uid': p.uid,
        'name': p.name,
        'expenses': [
          for (final e in p.expenses)
            {
              'uid': e.uid,
              'date': _iso(e.date),
              'merchant': e.merchant,
              'amount': e.amount,
              'category': e.category,
              'note': e.note,
              'items': [
                for (final i in e.items) {'name': i.name, 'amount': i.amount, 'category': i.category},
              ],
            },
        ],
      },
  ],
});

const csvHeader = [
  'profil', 'profil_uid', 'fis_uid', 'tarih', 'isyeri', 'toplam', 'kategori', 'not',
  'kalem_adi', 'kalem_tutar', 'kalem_kategori',
];

/// Excel (Türkçe) için: UTF-8 BOM, `;` ayracı, ondalık virgül. `= + - @` ile başlayan metinler formül
/// enjeksiyonuna karşı `'` ile öne alınır (içe aktarırken geri alınır).
String exportCsv(BackupData b) {
  String q(String v, {bool text = true}) {
    var s = v;
    if (text && s.isNotEmpty && '=+-@'.contains(s[0])) s = "'$s";
    if (s.contains(';') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
      s = '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  String num(double v) => v.toStringAsFixed(2).replaceAll('.', ',');

  final sb = StringBuffer('﻿')..write('${csvHeader.join(';')}\r\n');
  for (final p in b.profiles) {
    for (final e in p.expenses) {
      final head = [q(p.name), q(p.uid, text: false), q(e.uid, text: false), _iso(e.date), q(e.merchant), num(e.amount), q(e.category), q(e.note)];
      if (e.items.isEmpty) {
        sb.write('${[...head, '', '', ''].join(';')}\r\n');
      } else {
        for (final i in e.items) {
          sb.write('${[...head, q(i.name), num(i.amount), q(i.category)].join(';')}\r\n');
        }
      }
    }
  }
  return sb.toString();
}

// ---------------------------------------------------------------- içe aktarma (ayrıştırma)

/// JSON veya CSV metnini doğrulayarak okur. Yapısal bozukluk (tanınmayan biçim, desteklenmeyen sürüm,
/// bozuk JSON) [FormatException] fırlatır; tek tek geçersiz fişler [BackupData.errors]'a yazılıp atlanır.
BackupData parseBackup(String text) {
  var t = text;
  if (t.startsWith('﻿')) t = t.substring(1);
  final trimmed = t.trimLeft();
  if (trimmed.isEmpty) throw const FormatException('Dosya boş.');
  if (trimmed.startsWith('{')) return _parseJson(trimmed);
  return _parseCsv(t);
}

BackupData _parseJson(String text) {
  final Object? root;
  try {
    root = jsonDecode(text);
  } on FormatException {
    throw const FormatException('Dosya geçerli bir JSON değil.');
  }
  if (root is! Map || root['format'] != backupFormat) {
    throw const FormatException('Bu dosya bir Fissio yedeği değil.');
  }
  final version = root['version'];
  if (version is! int || version < 1 || version > backupVersion) {
    throw FormatException('Desteklenmeyen yedek sürümü: $version.');
  }
  final plist = root['profiles'];
  if (plist is! List) throw const FormatException('Yedekte profil listesi yok.');
  if (plist.length > _maxProfiles) throw const FormatException('Çok fazla profil.');

  final errors = <String>[];
  final profiles = <BackupProfile>[];
  var total = 0;
  for (var pi = 0; pi < plist.length; pi++) {
    final p = plist[pi];
    if (p is! Map || p['name'] is! String || (p['name'] as String).trim().isEmpty) {
      errors.add('Profil ${pi + 1}: ad eksik, atlandı.');
      continue;
    }
    final pname = _clip(p['name'] as String, 40);
    final puid = (p['uid'] is String && _uidOk(p['uid'] as String)) ? p['uid'] as String : '';
    final elist = p['expenses'];
    final exps = <BackupExpense>[];
    if (elist is List) {
      for (var ei = 0; ei < elist.length; ei++) {
        if (++total > _maxExpenses) throw const FormatException('Çok fazla fiş.');
        final label = '$pname, fiş ${ei + 1}';
        final e = elist[ei];
        if (e is! Map) {
          errors.add('$label: geçersiz kayıt.');
          continue;
        }
        final r = _expenseFrom(
          uid: e['uid'] is String ? e['uid'] as String : '',
          dateRaw: '${e['date'] ?? ''}',
          merchant: '${e['merchant'] ?? ''}',
          amount: e['amount'] is num ? (e['amount'] as num).toDouble() : parseAmount('${e['amount'] ?? ''}'),
          category: '${e['category'] ?? ''}',
          note: '${e['note'] ?? ''}',
          rawItems: [
            if (e['items'] is List)
              for (final i in e['items'] as List)
                if (i is Map)
                  (
                    name: '${i['name'] ?? ''}',
                    amount: i['amount'] is num ? (i['amount'] as num).toDouble() : parseAmount('${i['amount'] ?? ''}'),
                    category: '${i['category'] ?? ''}',
                  ),
          ],
        );
        if (r.error != null) {
          errors.add('$label: ${r.error}');
        } else {
          exps.add(r.value!);
        }
      }
    }
    profiles.add(BackupProfile(puid, pname, exps));
  }
  return BackupData(version, DateTime.tryParse('${root['exported_at'] ?? ''}'), profiles, errors);
}

bool _uidOk(String s) => RegExp(r'^[A-Za-z0-9._:-]{1,64}$').hasMatch(s);

({BackupExpense? value, String? error}) _expenseFrom({
  required String uid,
  required String dateRaw,
  required String merchant,
  required double? amount,
  required String category,
  required String note,
  required List<({String name, double? amount, String category})> rawItems,
}) {
  final date = parseDate(dateRaw);
  if (date == null) return (value: null, error: 'tarih okunamadı ("$dateRaw").');
  if (amount == null || amount < 0.01 || amount >= 1e10) return (value: null, error: 'tutar geçersiz.');
  if (rawItems.length > _maxItems) return (value: null, error: 'en çok $_maxItems kalem olabilir.');
  final items = <BackupItem>[];
  for (final i in rawItems) {
    if (i.amount == null || i.amount! < 0 || i.amount! >= 1e10) return (value: null, error: 'kalem tutarı geçersiz.');
    items.add(BackupItem(_clip(i.name, 100), (i.amount! * 100).round() / 100, i.category.trim()));
  }
  return (
    value: BackupExpense(
      uid: _uidOk(uid) ? uid : '',
      date: date,
      merchant: _clip(merchant, 100),
      amount: (amount * 100).round() / 100,
      category: category.trim(),
      note: _clip(note, 500),
      items: items,
    ),
    error: null,
  );
}

/// RFC 4180 benzeri ayrıştırıcı (tırnaklı alan, "" kaçışı, alan içinde satır sonu).
List<List<String>> _csvRows(String text, String delim) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"' && cell.isEmpty) {
      inQuotes = true;
    } else if (ch == delim) {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.any((c) => c.isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      cell.write(ch);
    }
  }
  if (inQuotes) throw const FormatException('CSV bozuk: kapanmamış tırnak.');
  row.add(cell.toString());
  if (row.any((c) => c.isNotEmpty)) rows.add(row);
  return rows;
}

String _unescapeFormula(String s) =>
    (s.length > 1 && s[0] == "'" && '=+-@'.contains(s[1])) ? s.substring(1) : s;

BackupData _parseCsv(String text) {
  final firstLine = text.split(RegExp(r'\r?\n')).first;
  // Ayraç: başlıkta en çok geçen aday.
  var delim = ';';
  var best = -1;
  for (final d in [';', ',', '\t']) {
    final n = d.allMatches(firstLine).length;
    if (n > best) {
      best = n;
      delim = d;
    }
  }
  final rows = _csvRows(text, delim);
  if (rows.isEmpty) throw const FormatException('CSV boş.');
  final header = rows.first.map((h) => h.trim().toLowerCase()).toList();
  int col(String n) => header.indexOf(n);
  final cDate = col('tarih'), cMerchant = col('isyeri'), cTotal = col('toplam');
  if (cDate < 0 || cMerchant < 0 || cTotal < 0) {
    throw const FormatException('CSV başlığı tanınmadı (tarih, isyeri, toplam sütunları gerekli).');
  }
  final cProfile = col('profil'), cProfileUid = col('profil_uid'), cUid = col('fis_uid');
  final cCat = col('kategori'), cNote = col('not');
  final cItem = col('kalem_adi'), cItemAmt = col('kalem_tutar'), cItemCat = col('kalem_kategori');
  String at(List<String> r, int c) => (c >= 0 && c < r.length) ? _unescapeFormula(r[c].trim()) : '';

  if (rows.length - 1 > _maxExpenses * 10) throw const FormatException('Çok fazla satır.');
  final errors = <String>[];
  // profil adı -> (uid, fiş anahtarı -> bilgiler)
  final profiles = <String, ({String uid, Map<String, _CsvReceipt> receipts})>{};
  for (var ri = 1; ri < rows.length; ri++) {
    final r = rows[ri];
    final line = ri + 1;
    final pname = at(r, cProfile).isEmpty ? 'İçe aktarılan' : _clip(at(r, cProfile), 40);
    final dateRaw = at(r, cDate);
    final totalRaw = at(r, cTotal);
    final uid = at(r, cUid);
    final key = uid.isNotEmpty ? 'u:$uid' : 'k:$dateRaw|${at(r, cMerchant)}|$totalRaw|${at(r, cNote)}';
    final prof = profiles.putIfAbsent(pname, () => (uid: at(r, cProfileUid), receipts: {}));
    final rec = prof.receipts.putIfAbsent(
      key,
      () => _CsvReceipt(line, uid, dateRaw, at(r, cMerchant), parseAmount(totalRaw), at(r, cCat), at(r, cNote)),
    );
    final itemName = at(r, cItem);
    final itemAmtRaw = at(r, cItemAmt);
    if (itemName.isNotEmpty || itemAmtRaw.isNotEmpty) {
      rec.items.add((name: itemName, amount: parseAmount(itemAmtRaw), category: at(r, cItemCat)));
    }
  }
  final out = <BackupProfile>[];
  var total = 0;
  for (final entry in profiles.entries) {
    final exps = <BackupExpense>[];
    for (final rec in entry.value.receipts.values) {
      if (++total > _maxExpenses) throw const FormatException('Çok fazla fiş.');
      final r = _expenseFrom(
        uid: rec.uid,
        dateRaw: rec.dateRaw,
        merchant: rec.merchant,
        amount: rec.amount,
        category: rec.category,
        note: rec.note,
        rawItems: rec.items,
      );
      if (r.error != null) {
        errors.add('Satır ${rec.line}: ${r.error}');
      } else {
        exps.add(r.value!);
      }
    }
    out.add(BackupProfile(_uidOk(entry.value.uid) ? entry.value.uid : '', entry.key, exps));
  }
  return BackupData(backupVersion, null, out, errors);
}

class _CsvReceipt {
  _CsvReceipt(this.line, this.uid, this.dateRaw, this.merchant, this.amount, this.category, this.note);
  final int line;
  final String uid;
  final String dateRaw;
  final String merchant;
  final double? amount;
  final String category;
  final String note;
  final List<({String name, double? amount, String category})> items = [];
}

// ---------------------------------------------------------------- içe aktarma (uygulama)

/// Doğrulanmış yedeği uygulamaya yazar: aynı fişler (client_uid VEYA parmak izi) yeniden eklenmez, yani iki
/// kez içe aktarmak mükerrer üretmez. Eklenenler senkron açıksa buluta idempotent yüklenir (çevrimdışıysa
/// kuyrukta bekler), kapalıysa yalnızca cihazda kalır.
Future<ImportSummary> importBackup(AppState app, BackupData data) async {
  final existingUids = {for (final e in app.allExpenses) e.clientUid};
  final profileById = {for (final p in app.profiles) p.id: p};
  final existingFp = <String>{
    for (final e in app.allExpenses)
      fingerprint(profileById[e.profileUid]?.name ?? '', e.date, e.merchant, e.amount, [
        for (final i in e.items) BackupItem(i.name, i.amount, ''),
      ]),
  };
  int? catId(String name) {
    final n = name.trim().toLowerCase();
    if (n.isNotEmpty) {
      for (final c in app.categories) {
        if (c.name.toLowerCase() == n) return c.id;
      }
    }
    return app.categories.where((c) => c.name == 'Diğer').firstOrNull?.id;
  }

  int? itemCat(String name) => name.trim().isEmpty ? null : catId(name);
  var imported = 0, skipped = 0, created = 0;
  final errors = [...data.errors];
  for (final bp in data.profiles) {
    if (bp.expenses.isEmpty) continue;
    final before = app.profiles.length;
    final profile = await app.ensureProfileForImport(
      uid: bp.uid.isNotEmpty ? bp.uid : newClientUid('p'),
      name: bp.name,
    );
    if (app.profiles.length > before) created++;
    for (final be in bp.expenses) {
      final fp = fingerprint(profile.name, be.date, be.merchant, be.amount, be.items);
      final uid = be.uid.isNotEmpty ? be.uid : uidFromFingerprint(fp);
      if (existingUids.contains(uid) || existingFp.contains(fp)) {
        skipped++;
        continue;
      }
      existingUids.add(uid);
      existingFp.add(fp);
      final cid = catId(be.category) ?? 0;
      await app.addImportedExpense(
        Expense(
          id: 0,
          merchant: be.merchant,
          amount: be.amount,
          date: be.date,
          categoryId: cid,
          categoryName: app.categories.where((c) => c.id == cid).map((c) => c.name).firstOrNull ?? 'Diğer',
          note: be.note,
          items: [
            for (final i in be.items)
              ExpenseItem(
                i.name,
                i.amount,
                categoryId: itemCat(i.category),
                categoryName: app.categories.where((c) => c.id == itemCat(i.category)).map((c) => c.name).firstOrNull,
              ),
          ],
          clientUid: uid,
          profileUid: profile.id,
        ),
      );
      imported++;
    }
  }
  await app.finishImport();
  return ImportSummary(imported, skipped, created, errors);
}
