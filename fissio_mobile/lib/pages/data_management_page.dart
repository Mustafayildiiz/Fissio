import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_state.dart';
import '../data/data_transfer.dart';
import '../data/file_transfer.dart';
import '../dialogs.dart';
import '../models.dart' show Expense;
import '../theme.dart';
import '../widgets.dart';

/// Ayarlar > Veri Yönetimi: bulut senkronu anahtarı (varsayılan açık), JSON/CSV dışa aktarma ve yedekten
/// (JSON/CSV) içe aktarma. İçe aktarma biçimi doğrular ve aynı fişleri mükerrer eklemez.
class DataManagementPage extends StatefulWidget {
  const DataManagementPage({super.key, this.transfer = const PluginFileTransfer(), this.now, this.app});

  /// Testlerde sahte verilir (eklentisiz).
  final FileTransfer transfer;
  final DateTime Function()? now;

  /// Verilmezse global [appState] (testlerde sahte sunuculu örnek verilir).
  final AppState? app;

  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage> {
  AppState get _app => widget.app ?? appState;
  bool _allAccount = false;
  bool _busy = false;

  Future<void> _toggleSync(bool value) async {
    if (!value) {
      final ok = await showConfirmDialog(
        context,
        title: 'Bulut senkronu kapatılsın mı?',
        message:
            'Kapalıyken yeni eklenen fişler ve profiller yalnızca bu cihazda saklanır, sunucuya gönderilmez. '
            'Mevcut bulut kayıtların görünmeye devam eder ancak değiştirilemez. Senkronu tekrar açtığında '
            'cihazdaki kayıtlar buluta aktarılır.\n\n'
            'Not: Fiş tarama, fotoğrafı yalnızca metne çevirmek için geçici olarak sunucuya gönderir; saklanmaz.',
        confirmLabel: 'Kapat',
      );
      if (!ok) return;
    }
    try {
      await _app.setSyncEnabled(value);
      if (mounted) {
        showMessage(
          context,
          value
              ? 'Bulut senkronu açıldı; cihazdaki kayıtlar yükleniyor.'
              : 'Bulut senkronu kapatıldı; yeni kayıtlar yalnızca bu cihazda tutulacak.',
        );
      }
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  /// Çakışan çevrimdışı düzenlemeleri tek tek sorar: kullanıcının hali mi, sunucudaki (başka cihazda yapılmış) hal mi.
  Future<void> _resolveConflicts() async {
    for (final x in _app.editConflicts) {
      if (!mounted) return;
      String desc(Expense e) => '${e.merchant.isEmpty ? 'Fiş' : e.merchant} · ${fmtMoney(e.amount)}';
      final keepMine = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Düzenleme çakışması'),
          content: Text(
            'Bu fiş, sen çevrimdışıyken başka bir yerde de değiştirildi.\n\n'
            'Senin düzenlemen: ${desc(x.mine)}\n'
            'Sunucudaki: ${x.server == null ? '-' : desc(x.server!)}',
          ),
          actions: [
            TextButton(
              key: const Key('conflict-take-server'),
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Sunucudakini al'),
            ),
            TextButton(
              key: const Key('conflict-keep-mine'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Benimkini koru'),
            ),
          ],
        ),
      );
      if (keepMine == null) return; // pencere kapatıldı: kalanlar sonra
      try {
        await _app.resolveEditConflict(x.mine.id, keepMine: keepMine);
      } on ApiException catch (e) {
        if (mounted) showMessage(context, e.message);
        return;
      }
    }
  }

  BackupData _backup() {
    final p = _app.activeProfile;
    return buildBackup(
      _app.profiles,
      _app.allExpenses,
      profileId: _allAccount ? null : p?.id,
      now: widget.now?.call(),
    );
  }

  Future<void> _export(String format) async {
    if (_busy) return;
    final b = _backup();
    if (b.expenseCount == 0) {
      showMessage(context, 'Dışa aktarılacak fiş yok.');
      return;
    }
    final stamp = (widget.now?.call() ?? DateTime.now()).toIso8601String().substring(0, 10);
    final isJson = format == 'json';
    final filename = 'fissio-yedek-$stamp.${isJson ? 'json' : 'csv'}';
    final text = isJson ? exportJson(b) : exportCsv(b);
    final bytes = Uint8List.fromList(utf8.encode(text));
    final mime = isJson ? 'application/json' : 'text/csv';

    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(filename, style: FissioText.title(ctx.c, size: 18)),
              const SizedBox(height: 4),
              Text('${b.expenseCount} fiş', style: FissioText.body(ctx.c, size: 14, color: ctx.c.mute)),
              const SizedBox(height: 12),
              GroupedCard(
                children: [
                  ListRow(
                    leading: IconTile(LucideIcons.share2, size: 30, radius: 8),
                    title: 'Paylaş…',
                    onTap: () => Navigator.pop(ctx, 'share'),
                  ),
                  ListRow(
                    leading: IconTile(LucideIcons.download, size: 30, radius: 8),
                    title: 'Cihaza kaydet',
                    onTap: () => Navigator.pop(ctx, 'save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    try {
      if (choice == 'share') {
        await widget.transfer.share(filename: filename, bytes: bytes, mimeType: mime);
      } else {
        final ok = await widget.transfer.saveToDevice(filename: filename, bytes: bytes, mimeType: mime);
        if (mounted && ok) showMessage(context, 'Dosya kaydedildi.');
      }
    } catch (_) {
      if (mounted) showMessage(context, 'Dosya dışa aktarılamadı.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    ({String name, String text})? picked;
    try {
      picked = await widget.transfer.pickBackup();
    } catch (_) {
      if (mounted) showMessage(context, 'Dosya seçilemedi.');
      return;
    }
    if (picked == null || !mounted) return;
    final BackupData data;
    try {
      data = parseBackup(picked.text);
    } on FormatException catch (e) {
      if (mounted) showMessage(context, 'İçe aktarılamadı: ${e.message}');
      return;
    }
    if (!mounted) return;
    if (data.expenseCount == 0) {
      showMessage(context, data.errors.isEmpty ? 'Dosyada fiş yok.' : 'Dosyada geçerli fiş bulunamadı.');
      return;
    }
    final ok = await showConfirmDialog(
      context,
      title: 'Yedek yüklensin mi?',
      message:
          '${data.profiles.length} profilde ${data.expenseCount} fiş bulundu'
          '${data.errors.isEmpty ? '' : ' (${data.errors.length} kayıt geçersiz, atlanacak)'}. '
          'Hesabında zaten bulunan fişler tekrar eklenmez.',
      confirmLabel: 'Yükle',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await importBackup(_app, data);
      if (!mounted) return;
      setState(() => _busy = false); // sonuç penceresi açıkken arkada yükleniyor göstergesi dönmesin
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('İçe aktarma tamamlandı'),
          content: Text(
            '${r.imported} fiş eklendi\n'
            '${r.skipped} fiş zaten vardı (atlandı)\n'
            '${r.profilesCreated} yeni profil'
            '${r.errors.isEmpty ? '' : '\n${r.errors.length} geçersiz kayıt atlandı'}',
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam'))],
        ),
      );
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const NavBackBar(label: 'Ayarlar'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text('Veri Yönetimi', style: FissioText.title(c)),
            ),
            const Rule2(margin: EdgeInsets.fromLTRB(20, 16, 20, 8)),
            Expanded(
              child: ListenableBuilder(
                listenable: _app,
                builder: (context, _) {
                  final pending = _app.pendingCount;
                  final localOnly = _app.localOnlyCount;
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                    children: [
                      const SectionLabel('Bulut senkronizasyonu'),
                      GroupedCard(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Buluta kaydet', style: FissioText.body(c, weight: FontWeight.w600)),
                                    const SizedBox(height: 2),
                                    Text(
                                      _app.syncEnabled
                                          ? 'Fiş ve profillerin hesabına bağlı olarak sunucuda saklanır.'
                                          : 'Yeni fiş ve profiller yalnızca bu cihazda tutulur.',
                                      style: FissioText.body(c, size: 13, color: c.mute),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                key: const Key('sync-switch'),
                                value: _app.syncEnabled,
                                activeTrackColor: c.accent,
                                onChanged: _busy ? null : _toggleSync,
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (pending > 0 || localOnly > 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  pending > 0
                                      ? '$pending kayıt bağlantı gelince buluta yüklenecek.'
                                            '${_app.failedSyncCount > 0 ? '\n${_app.failedSyncCount} kayıt sunucu tarafından kabul edilmedi; fişi düzenleyin ya da silin.' : ''}'
                                      : '$localOnly kayıt yalnızca bu cihazda.',
                                  key: const Key('sync-status'),
                                  style: FissioText.body(c, size: 13, color: c.mute),
                                ),
                              ),
                              if (pending > 0)
                                TextButton(
                                  onPressed: () => _app.flushNow(force: true),
                                  child: const Text('Şimdi yükle'),
                                ),
                            ],
                          ),
                        ),
                      if (_app.conflictedEditCount > 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${_app.conflictedEditCount} düzenleme sunucudakiyle çakıştı.',
                                  key: const Key('conflict-status'),
                                  style: FissioText.body(c, size: 13, color: c.mute),
                                ),
                              ),
                              TextButton(
                                key: const Key('conflict-resolve'),
                                onPressed: _resolveConflicts,
                                child: const Text('İncele'),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                      const SectionLabel('Verileri dışa aktar'),
                      SegmentedControl<bool>(
                        value: _allAccount,
                        onChanged: (v) => setState(() => _allAccount = v),
                        items: [
                          SegmentItem(false, _app.profileName ?? 'Aktif profil'),
                          const SegmentItem(true, 'Tüm hesap'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      GroupedCard(
                        children: [
                          ListRow(
                            key: const Key('export-json'),
                            leading: IconTile(LucideIcons.fileJson, size: 36, radius: 10),
                            title: 'JSON olarak dışa aktar',
                            subtitle: 'Tam yedek; tekrar yüklenebilir',
                            onTap: () => _export('json'),
                          ),
                          ListRow(
                            key: const Key('export-csv'),
                            leading: IconTile(LucideIcons.fileSpreadsheet, size: 36, radius: 10),
                            title: 'CSV olarak dışa aktar',
                            subtitle: 'Excel / tablo incelemesi için',
                            onTap: () => _export('csv'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const SectionLabel('Uygulamaya veri yükle'),
                      GroupedCard(
                        children: [
                          ListRow(
                            key: const Key('import'),
                            leading: IconTile(LucideIcons.upload, size: 36, radius: 10),
                            title: 'Yedek dosyası seç',
                            subtitle: 'JSON veya CSV; aynı fişler tekrar eklenmez',
                            onTap: _import,
                          ),
                        ],
                      ),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                        child: Text(
                          'Dışa aktarma fiş fotoğraflarını içermez. Fotoğraflar buluta kaydedilir ve hesabınla birlikte silinir.',
                          style: FissioText.body(c, size: 13, color: c.mute),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
