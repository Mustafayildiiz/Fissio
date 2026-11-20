import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/deep_links.dart';
import 'digital_import.dart';
import '../widgets.dart';
import 'home_page.dart';
import 'receipts_page.dart';
import 'scan_page.dart';

/// Kök sayfa: Özet ve Fişler sekmeleri, ortada yeni fiş "+" eylemi.
/// (Kaydetme akışı `popUntil(isFirst)` ile buraya döner; bu sayfa ilk route kalmalıdır.)
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int _index = 0; // 0: Özet, 1: Fişler
  final _filter = ValueNotifier<int?>(null); // kategori filtresi (Özet'ten gelir)

  @override
  void initState() {
    super.initState();
    appState.refresh();
    // Ana ekran widget'ından gelen "hızlı tara" (fissio://scan): soğuk açılışta bekleyen istek ilk karede,
    // sıcak açılışta (arka plandan) geldiği anda tüketilir.
    deepLinks.addListener(_maybeOpenDeepLink);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOpenDeepLink());
  }

  @override
  void dispose() {
    deepLinks.removeListener(_maybeOpenDeepLink);
    _filter.dispose();
    super.dispose();
  }

  /// Bekleyen hızlı eylem: `fissio://scan` → kamera; `fissio://import-digital` ya da paylaşılan PDF → dijital fiş akışı.
  void _maybeOpenDeepLink() {
    if (!mounted || !appState.loggedIn || appState.activeProfile == null) return;
    if (deepLinks.consumeScan()) {
      _addReceipt();
      return;
    }
    final imp = deepLinks.consumeImport();
    if (imp != null) _importDigital(imp.path);
  }

  bool _importOpen = false;

  /// Dijital fiş / PDF akışı (kamera sayfasına uğramadan): paylaşılan dosya varsa doğrudan okunur, yoksa seçici açılır.
  Future<void> _importDigital(String? path) async {
    // Widget'a art arda dokunulursa ikinci akış üst üste açılmasın.
    if (_importOpen || _scanOpen) return;
    _importOpen = true;
    try {
      await runDigitalImport(context, path: path);
    } finally {
      _importOpen = false;
    }
  }

  void _openCategory(int? categoryId) {
    _filter.value = categoryId;
    setState(() => _index = 1);
  }

  bool _scanOpen = false;

  void _addReceipt() {
    // Widget'a art arda dokunulursa ikinci bir tarama sayfası üst üste açılmasın.
    if (_scanOpen) return;
    _scanOpen = true;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ScanPage()))
        .whenComplete(() => _scanOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: IndexedStack(
                index: _index,
                children: [
                  HomePage(
                    onOpenCategory: (id) => _openCategory(id),
                    onOpenAll: () => _openCategory(null),
                  ),
                  ReceiptsPage(categoryFilter: _filter),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FissioTabBar(
              index: _index,
              onTab: (i) => setState(() => _index = i),
              onAdd: _addReceipt,
            ),
          ),
        ],
      ),
    );
  }
}
