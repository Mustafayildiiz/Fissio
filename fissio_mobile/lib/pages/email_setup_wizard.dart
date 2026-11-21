import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api.dart';
import '../app_info.dart' show clipboardWriter, externalLinkLauncher;
import '../app_state.dart';
import '../dialogs.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt_detail_page.dart';

/// Gmail'de "Filtre oluştur" > "Şu kelimeleri içerir" alanına yapıştırılacak hazır arama sorgusu: fatura / fiş / sipariş /
/// makbuz / ödeme / bilet mailleri; bülten, kampanya ve indirim mailleri dışlanır.
const kGmailFilterQuery =
    '(fatura OR "e-arşiv" OR "e-fatura" OR "e-arsiv" OR fiş OR sipariş OR makbuz OR ödeme OR bilet) -bülten -kampanya -indirim';

String _two(int v) => v.toString().padLeft(2, '0');

/// "20.11.2026 23:05" biçimi.
String _fmtWhen(DateTime d) => '${d.day}.${_two(d.month)}.${d.year} ${_two(d.hour)}:${_two(d.minute)}';

/// Sunucudaki son webhook sonucunu (`InboundAddress.lastStatus`) kullanıcıya Türkçe, eyleme dönük bir satıra çevirir; bilinmiyorsa null.
String? emailLastStatusMessage(String? status) => _EmailSetupWizardPageState.lastStatusMessage(status);

/// Aktarım geçmişi satırındaki durum rozeti: (etiket, uyarı mı). Sunucu `status` (saved|ignored|failed) + `reason`.
({String label, bool warn, bool error}) emailHistoryBadge(InboundHistoryItem it) {
  if (it.saved) return (label: 'Kaydedildi', warn: false, error: false);
  if (it.status == 'failed') return (label: 'Hata', warn: false, error: true);
  return switch (it.reason) {
    'no_amount' => (label: 'Tutar Bulunamadı', warn: true, error: false),
    'pdf_unreadable' => (label: 'PDF Okunamadı', warn: true, error: false),
    'duplicate_document' || 'duplicate_order' || 'already_imported' => (label: 'Zaten Kayıtlı', warn: false, error: false),
    'gmail_confirmation' || 'gmail_confirmation_unreadable' => (label: 'Gmail Onayı', warn: false, error: false),
    'rate_limited' => (label: 'Sınır Aşıldı', warn: true, error: false),
    _ => (label: 'Atlandı', warn: true, error: false),
  };
}

/// Onay kodu yoklama aralığı (sihirbaz açıkken); testlerde kısaltılır.
const kConfirmationPollInterval = Duration(seconds: 5);

/// İnteraktif "E-Posta ile Otomatik Fiş Aktarımı" sihirbazı (Ayarlar, ilk açılış onboarding'i "Şimdi Kur" ve ana sayfa kartı).
///
/// Sekme 1 — Tam otomatik: (1) kullanıcıya özel yönlendirme adresi (tek tıkla kopyala), (2) Gmail/Outlook yönlendirme rehberi +
/// Gmail onay maili düşünce canlı görünen "Onay Kodu Geldi" kartı (kopyala / onay bağlantısını aç), (3) hazır Gmail filtre
/// sorgusu (kopyala). Sekme 2 — Kurulumsuz: mail uygulamasından özel adrese İlet (Forward) ve Paylaş → Fissio. Durum satırı:
/// "Aktif — Son aktarım: …".
class EmailSetupWizardPage extends StatefulWidget {
  const EmailSetupWizardPage({super.key, this.app, this.pollInterval = kConfirmationPollInterval});

  /// Verilmezse global [appState].
  final AppState? app;
  final Duration pollInterval;

  @override
  State<EmailSetupWizardPage> createState() => _EmailSetupWizardPageState();
}

class _EmailSetupWizardPageState extends State<EmailSetupWizardPage> {
  AppState get _app => widget.app ?? appState;

  bool _loading = true;
  int _tab = 0;
  ForwardingConfirmation? _confirmation;
  Timer? _timer;
  List<InboundHistoryItem> _history = const [];
  String? _historyStamp;

  @override
  void initState() {
    super.initState();
    _app.addListener(_onApp);
    unawaited(_load());
  }

  void _onApp() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _app.removeListener(_onApp);
    super.dispose();
  }

  Future<void> _load() async {
    await _app.markEmailImportSeen();
    await _app.loadInbound();
    if (!mounted) return;
    setState(() => _loading = false);
    if (_app.emailImportAvailable) {
      unawaited(_alignProfile());
      unawaited(_refreshHistory());
      _poll();
      _timer = Timer.periodic(widget.pollInterval, (_) => _poll());
    }
  }

  /// Geçmişi çeker; üst karttaki son aktarım zamanı/durumu da AYNI anda tazelenir (kart `AppState.inbound`'dan okur):
  /// geçmişte görünen bir mail üst kartta eski tarihle kalmasın.
  Future<void> _refreshHistory() async {
    final list = await _app.loadInboundHistory();
    await _app.loadInbound();
    if (!mounted || list == null) return;
    final info = _app.inbound;
    setState(() {
      _history = list;
      _historyStamp = '${info?.lastReceivedAt?.toIso8601String()}|${info?.lastStatus}';
    });
  }

  /// "Fişe git": fiş bellekte yoksa (henüz çekilmemiş) önce liste yenilenir; yine yoksa bilgi verilir.
  Future<void> _openReceipt(InboundHistoryItem it) async {
    final id = it.expenseId;
    if (id == null) return;
    if (!_app.expenses.any((x) => x.id == id)) {
      await _app.refresh();
      if (!mounted) return;
    }
    if (!_app.expenses.any((x) => x.id == id)) {
      showMessage(context, 'Fiş bulunamadı; silinmiş ya da henüz eşitlenmemiş olabilir.');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiptDetailPage(id: id, app: widget.app)));
  }

  /// Aktarılan fişler aktif profile düşsün (sunucu "aktif profil"i bilmez): seçili değilse sessizce ayarlanır.
  Future<void> _alignProfile() async {
    final p = _app.activeProfile;
    final info = _app.inbound;
    if (p == null || p.serverId == null || info == null || info.profileId == p.serverId) return;
    try {
      await _app.setInboundProfile(p);
    } on ApiException {
      // Sessiz: profil seçimi isteğe bağlıdır (varsayılan profil kullanılır).
    }
  }

  Future<void> _poll() async {
    final conf = await _app.pollForwardingConfirmation();
    if (!mounted) return;
    // Aktarım başladıysa (ilk e-posta işlendi) durum satırı da güncellensin.
    await _app.loadInbound();
    if (!mounted) return;
    setState(() => _confirmation = conf ?? _confirmation);
    // Geçmiş yalnız yeni bir aktarım olduğunda (son durum/zaman değişince) yeniden çekilir.
    final info = _app.inbound;
    if ('${info?.lastReceivedAt?.toIso8601String()}|${info?.lastStatus}' != _historyStamp) await _refreshHistory();
  }

  Future<void> _copy(String text, String done) async {
    await clipboardWriter(text);
    if (mounted) showMessage(context, done);
  }

  Future<void> _openLink(String link) async {
    final ok = await externalLinkLauncher(Uri.parse(link));
    if (!ok && mounted) {
      await clipboardWriter(link);
      if (mounted) showMessage(context, 'Bağlantı açılamadı; panoya kopyalandı.');
    }
  }

  Future<void> _rotate() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Adresi yenile',
      message: 'Mevcut adres hemen geçersiz olur; Gmail/Outlook yönlendirmesini yeni adresle yeniden kurman gerekir.',
      confirmLabel: 'Yenile',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await _app.rotateInbound();
      if (mounted) {
        setState(() => _confirmation = null);
        showMessage(context, 'Yeni adres oluşturuldu.');
      }
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
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
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('E-Posta ile Otomatik Fiş Aktarımı', style: FissioText.title(c, size: 28)),
            ),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final c = context.c;
    if (_loading) {
      return const Center(key: ValueKey('wiz-loading'), child: CircularProgressIndicator());
    }
    if (!_app.syncEnabled) {
      return _notice(
        'Bulut senkronu kapalı',
        'E-postadan otomatik aktarım fişleri hesabına yazar; bunun için Ayarlar > Veri Yönetimi\'nden bulut senkronunu aç. '
            'Senkron kapalıyken yine de mail uygulamasından Paylaş → Fissio ile fişleri bu cihazda işleyebilirsin.',
        key: 'wiz-sync-off',
        showShare: true,
      );
    }
    final info = _app.inbound;
    if (info == null || !info.enabled) {
      return _notice(
        info == null ? 'Adres alınamadı' : 'Bu sunucuda e-posta aktarımı kapalı',
        info == null
            ? 'Sunucuya ulaşılamadı. Bağlantını kontrol edip tekrar dene.'
            : 'Hesabını barındıran sunucuda e-posta ile fiş aktarımı yapılandırılmamış. Mail uygulamasından Paylaş → Fissio '
                  'ile fişleri yine cihazda işleyebilirsin.',
        key: 'wiz-disabled',
        showShare: info != null,
        retry: info == null,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
      children: [
        _statusLine(c, info),
        const SizedBox(height: 14),
        SegmentedControl<int>(
          key: const ValueKey('wiz-tabs'),
          items: const [SegmentItem(0, 'Tam Otomatik (Önerilen)'), SegmentItem(1, 'Kurulumsuz Hızlı Kullanım')],
          value: _tab,
          onChanged: (v) => setState(() => _tab = v),
          fontSize: 13,
        ),
        const SizedBox(height: 16),
        if (_tab == 0) ..._autoTab(c, info) else ..._manualTab(c, info),
        _historySection(c),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('wiz-rotate'),
            onPressed: _rotate,
            child: Text('Adresi yenile', style: FissioText.body(c, size: 14, weight: FontWeight.w600, color: c.mute)),
          ),
        ),
      ],
    );
  }

  Widget _notice(String title, String body, {required String key, bool showShare = false, bool retry = false}) {
    final c = context.c;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        Container(
          key: ValueKey(key),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: c.surf, borderRadius: BorderRadius.circular(kRadius)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: FissioText.body(c, size: 17, weight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(body, style: FissioText.body(c, size: 15, color: c.mute).copyWith(height: 1.4)),
              if (retry) ...[
                const SizedBox(height: 12),
                TextButton(
                  key: const ValueKey('wiz-retry'),
                  onPressed: () async {
                    setState(() => _loading = true);
                    await _load();
                  },
                  child: Text('Tekrar dene', style: FissioText.body(c, weight: FontWeight.w600, color: c.accentInk)),
                ),
              ],
            ],
          ),
        ),
        if (showShare) ...[const SizedBox(height: 16), ..._shareSteps(c)],
      ],
    );
  }

  Widget _statusLine(FissioColors c, InboundAddress info) {
    final active = info.active;
    final when = info.lastReceivedAt == null ? '' : _fmtWhen(info.lastReceivedAt!);
    final last = lastStatusMessage(info.lastStatus);
    final warn = (info.lastStatus?.startsWith('ignored:') ?? false) || (info.lastStatus?.startsWith('failed') ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _activeRow(c, active, when),
        if (last != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              last,
              key: const ValueKey('wiz-last-status'),
              style: FissioText.body(c, size: 13, weight: FontWeight.w600, color: warn ? c.warn : c.mute).copyWith(height: 1.35),
            ),
          ),
      ],
    );
  }

  Widget _activeRow(FissioColors c, bool active, String when) {
    return Container(
      key: const ValueKey('wiz-status'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: active ? c.accent.withValues(alpha: .12) : c.surf2,
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Row(
        children: [
          Icon(active ? LucideIcons.circleCheck : LucideIcons.clock, size: 18, color: active ? c.accentInk : c.mute),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              active ? 'Aktif — Son aktarım: $when' : 'Henüz e-posta alınmadı. Kurulumu tamamlayınca burada görünür.',
              style: FissioText.body(c, size: 14, weight: FontWeight.w600, color: active ? c.accentInk : c.mute),
            ),
          ),
        ],
      ),
    );
  }

  /// Sunucudaki son webhook sonucu (`last_status`) → kullanıcıya Türkçe, eyleme dönük satır. Yok sayılan/mükerrer mailler "Aktif"
  /// satırına yansımaz; bu satır kullanıcının neden fiş görmediğini söyler. Bilinmeyen durumlarda null (satır gösterilmez).
  static String? lastStatusMessage(String? status) {
    if (status == null || status.isEmpty) return null;
    return switch (status) {
      'created' => 'Son e-posta fişe dönüştürüldü.',
      'merged' => 'Son e-posta, mevcut sipariş kaydıyla birleştirildi.',
      'duplicate' || 'duplicate_document' || 'duplicate_order' => 'Son e-posta zaten kayıtlıydı; tekrar eklenmedi.',
      'gmail_confirmation' => 'Gmail onay maili alındı.',
      'ignored:pdf_unreadable' => 'Son e-postadaki PDF okunamadı. PDF\'i mail uygulamandan Paylaş → Fissio ile ekleyebilirsin.',
      'ignored:no_amount' => 'Son e-postada tutar bulunamadı; fiş olarak kaydedilmedi. Gerekirse Paylaş → Fissio ile ekle.',
      'ignored:rate_limited' => 'Kısa sürede çok fazla e-posta geldi; bir süre sonra tekrar dene.',
      _ when status.startsWith('failed') => 'Son e-posta işlenirken bir hata oluştu. Nedeni aşağıdaki listede; tekrar deneyebilir ya da Paylaş → Fissio ile ekleyebilirsin.',
      _ when status.startsWith('ignored:') => 'Son e-posta fiş olarak okunamadı. Gerekirse Paylaş → Fissio ile ekle.',
      _ => null,
    };
  }

  Widget _card(FissioColors c, {required String step, required String title, required List<Widget> children, Key? key}) {
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.surf, borderRadius: BorderRadius.circular(kRadius)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$step · $title'.toUpperCase(), style: FissioText.label(c)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _copyBox(FissioColors c, String text, {required Key copyKey, required String done, Key? textKey}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(color: c.surf2, borderRadius: BorderRadius.circular(kRadiusSm)),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              text,
              key: textKey,
              style: FissioText.body(c, size: 14, weight: FontWeight.w600).copyWith(fontFamily: 'monospace'),
            ),
          ),
          IconButton(
            key: copyKey,
            tooltip: 'Kopyala',
            onPressed: () => _copy(text, done),
            icon: Icon(LucideIcons.copy, size: 18, color: c.accentInk),
          ),
        ],
      ),
    );
  }

  List<Widget> _autoTab(FissioColors c, InboundAddress info) {
    final body = FissioText.body(c, size: 15, color: c.mute).copyWith(height: 1.4);
    final conf = _confirmation;
    final profile = _app.activeProfile;
    return [
      _card(
        c,
        step: '1',
        title: 'Sana özel adres',
        key: const ValueKey('wiz-step-1'),
        children: [
          _copyBox(c, info.address,
              copyKey: const ValueKey('wiz-copy-address'), textKey: const ValueKey('wiz-address'), done: 'Adres kopyalandı.'),
          const SizedBox(height: 10),
          Text(
            'Bu adres sana özel ve tahmin edilemez. Gelen e-faturalar${profile == null ? '' : ' "${profile.name}" profiline'} kaydedilir.',
            style: body,
          ),
        ],
      ),
      _card(
        c,
        step: '2',
        title: 'Yönlendirmeyi ekle',
        key: const ValueKey('wiz-step-2'),
        children: [
          Text(
            'Gmail: Ayarlar → Tüm ayarlar → Yönlendirme ve POP/IMAP → "Yönlendirme adresi ekle" → yukarıdaki adresi yapıştır. '
            'Google bu adrese bir onay maili gönderir; kod burada kendiliğinden görünür.\n\n'
            'Outlook: Ayarlar → Posta → Yönlendirme → yönlendirmeyi etkinleştir → adresi yapıştır.',
            style: body,
          ),
          const SizedBox(height: 12),
          if (conf == null)
            Row(
              key: const ValueKey('wiz-confirm-waiting'),
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(child: Text('Gmail onay maili bekleniyor…', style: FissioText.body(c, size: 14, color: c.mute))),
              ],
            )
          else
            Container(
              key: const ValueKey('wiz-confirm-card'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: c.accent.withValues(alpha: .12), borderRadius: BorderRadius.circular(kRadiusSm)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Kod ve bağlantı ayrı ayrı isteğe bağlıdır (sunucu kodsuz onayda yalnızca link yollar).
                  if (conf.hasCode)
                    Text('Onay Kodu Geldi: ${conf.code}',
                        key: const ValueKey('wiz-confirm-code'), style: FissioText.body(c, size: 17, weight: FontWeight.w800, color: c.accentInk))
                  else
                    Text('Gmail Onayı Geldi',
                        key: const ValueKey('wiz-confirm-title'), style: FissioText.body(c, size: 17, weight: FontWeight.w800, color: c.accentInk)),
                  const SizedBox(height: 8),
                  if (!conf.hasCode && !conf.hasLink)
                    Text('Onay maili alındı ancak kod/bağlantı okunamadı. Gmail\'de kodu elle gir ya da yönlendirmeyi yeniden ekle.',
                        key: const ValueKey('wiz-confirm-empty'), style: FissioText.body(c, size: 14, color: c.mute))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        if (conf.hasCode)
                          OutlinedButton.icon(
                            key: const ValueKey('wiz-copy-code'),
                            onPressed: () => _copy(conf.code!, 'Kod kopyalandı.'),
                            icon: const Icon(LucideIcons.copy, size: 16),
                            label: const Text('Kodu kopyala'),
                          ),
                        if (conf.hasLink && conf.hasCode)
                          OutlinedButton.icon(
                            key: const ValueKey('wiz-open-link'),
                            onPressed: () => _openLink(conf.link!),
                            icon: const Icon(LucideIcons.externalLink, size: 16),
                            label: const Text('Gmail Yönlendirmesini Onayla'),
                          )
                        else if (conf.hasLink)
                          // Kod yoksa onay yalnızca bu bağlantıyla yapılır: belirgin, doldurulmuş buton.
                          FilledButton.icon(
                            key: const ValueKey('wiz-open-link'),
                            onPressed: () => _openLink(conf.link!),
                            icon: const Icon(LucideIcons.externalLink, size: 16),
                            label: const Text('Gmail Yönlendirmesini Onayla'),
                          ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
      _card(
        c,
        step: '3',
        title: 'Gmail filtresi',
        key: const ValueKey('wiz-step-3'),
        children: [
          Text(
            'Bu filtre yalnızca fatura, fiş, sipariş, makbuz, ödeme ve bilet maillerini yakalar; bülten, kampanya ve indirim '
            'maillerini dışarıda bırakır. Sorguyu kopyala:',
            style: body,
          ),
          const SizedBox(height: 10),
          _copyBox(c, kGmailFilterQuery,
              copyKey: const ValueKey('wiz-copy-filter'), textKey: const ValueKey('wiz-filter'), done: 'Filtre sorgusu kopyalandı.'),
          const SizedBox(height: 14),
          for (final (i, s) in _filterSteps.indexed) _stepRow(c, i + 1, s),
        ],
      ),
    ];
  }

  static const _filterSteps = [
    'Gmail\'i bilgisayarda aç, arama kutusunun sağındaki ayar (filtre) simgesine dokun.',
    'Kopyaladığın sorguyu "Şu kelimeleri içerir" alanına yapıştır.',
    '"Filtre oluştur"a bas.',
    '"Şu adrese ilet" kutusunu işaretle ve yukarıdaki Fissio adresini seç (Adım 2\'de eklediğin için listede görünür).',
    '"Filtre oluştur" ile bitir. Bundan sonra eşleşen mailler kendiliğinden Fissio\'ya gelir.',
  ];

  Widget _stepRow(FissioColors c, int n, String text) {
    return Padding(
      key: ValueKey('wiz-filter-step-$n'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.accent.withValues(alpha: .14), shape: BoxShape.circle),
            child: Text('$n', style: FissioText.body(c, size: 12, weight: FontWeight.w800, color: c.accentInk)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: FissioText.body(c, size: 14, color: c.mute).copyWith(height: 1.4))),
        ],
      ),
    );
  }

  /// "Son Aktarılan E-Postalar": webhook'a gelen maillerin akıbeti (rozet + konu + tarih); kaydedilenler fişe gider.
  Widget _historySection(FissioColors c) {
    return Padding(
      key: const ValueKey('wiz-history'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text('SON AKTARILAN E-POSTALAR', style: FissioText.label(c)),
          ),
          if (_history.isEmpty)
            Container(
              key: const ValueKey('wiz-history-empty'),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: c.surf, borderRadius: BorderRadius.circular(kRadius)),
              child: Text('Henüz aktarılan e-posta yok.', style: FissioText.body(c, size: 14, color: c.mute)),
            )
          else
            Material(
              color: c.surf,
              borderRadius: BorderRadius.circular(kRadius),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [for (final it in _history) _historyRow(c, it)]),
            ),
        ],
      ),
    );
  }

  Widget _historyRow(FissioColors c, InboundHistoryItem it) {
    final b = emailHistoryBadge(it);
    final tone = b.error ? c.danger : (b.warn ? c.warn : c.accentInk);
    final subject = it.subject.trim().isEmpty ? '(Konusuz e-posta)' : it.subject.trim();
    return InkWell(
      key: ValueKey('wiz-history-${it.id}'),
      onTap: it.hasExpense ? () => _openReceipt(it) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(subject, maxLines: 2, overflow: TextOverflow.ellipsis, style: FissioText.body(c, size: 15, weight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    it.receivedAt == null ? '' : _fmtWhen(it.receivedAt!),
                    style: FissioText.body(c, size: 12, color: c.mute),
                  ),
                  // Hatanın gerçek nedeni (sunucu kısaltılmış yazar): "db_error: …" — destek/teşhis için görünür.
                  if (it.status == 'failed' && (it.reason ?? '').trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        it.reason!.trim(),
                        key: ValueKey('wiz-history-reason-${it.id}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: FissioText.body(c, size: 12, color: c.danger),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(color: tone.withValues(alpha: .14), borderRadius: BorderRadius.circular(999)),
              child: Text(b.label, style: FissioText.body(c, size: 12, weight: FontWeight.w700, color: tone)),
            ),
            if (it.hasExpense) ...[
              const SizedBox(width: 6),
              Icon(LucideIcons.chevronRight, size: 16, color: c.mute),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _manualTab(FissioColors c, InboundAddress info) {
    final body = FissioText.body(c, size: 15, color: c.mute).copyWith(height: 1.4);
    return [
      _card(
        c,
        step: 'A',
        title: 'Mail uygulamasından ilet',
        key: const ValueKey('wiz-forward'),
        children: [
          Text('Filtre kurmak istemiyorsan, e-faturanın geldiği maili açıp "İlet (Forward)" de ve alıcı olarak bu adresi yaz:', style: body),
          const SizedBox(height: 10),
          _copyBox(c, info.address, copyKey: const ValueKey('wiz-copy-address-2'), done: 'Adres kopyalandı.'),
          const SizedBox(height: 8),
          Text('Fissio, iletilen mailin önsözünü (Gönderen/Tarih/Konu) atıp fişi okur; aynı mail iki kez iletilse bile tek kayıt oluşur.', style: body),
        ],
      ),
      ..._shareSteps(c),
    ];
  }

  List<Widget> _shareSteps(FissioColors c) {
    final body = FissioText.body(c, size: 15, color: c.mute).copyWith(height: 1.4);
    return [
      _card(
        c,
        step: 'B',
        title: 'Paylaş → Fissio',
        key: const ValueKey('wiz-share'),
        children: [
          Text(
            'E-fatura PDF\'ini, .eml dosyasını ya da HTML sipariş özetini mail/dosya uygulamandan "Paylaş" ya da "Birlikte aç" '
            'ile Fissio\'ya gönder. Okuma cihazda yapılır; senkron kapalıyken de çalışır.',
            style: body,
          ),
        ],
      ),
    ];
  }
}
