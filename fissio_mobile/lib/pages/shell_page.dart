import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/deep_links.dart';
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
    deepLinks.addListener(_maybeOpenScan);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOpenScan());
  }

  @override
  void dispose() {
    deepLinks.removeListener(_maybeOpenScan);
    _filter.dispose();
    super.dispose();
  }

  void _maybeOpenScan() {
    if (!mounted || !appState.loggedIn || appState.activeProfile == null) return;
    if (!deepLinks.consumeScan()) return;
    _addReceipt();
  }

  void _openCategory(int? categoryId) {
    _filter.value = categoryId;
    setState(() => _index = 1);
  }

  void _addReceipt() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
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
