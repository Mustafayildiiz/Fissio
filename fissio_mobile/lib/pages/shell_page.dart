import 'package:flutter/material.dart';

import '../app_state.dart';
import '../widgets.dart';
import 'home_page.dart';
import 'receipts_page.dart';
import 'settings_page.dart';

class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int _index = 1; // Ana sayfa
  final _filter = ValueNotifier<int?>(null); // kategori filtresi (panelden gelir)

  @override
  void initState() {
    super.initState();
    appState.refresh();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _openCategory(int categoryId) {
    _filter.value = categoryId;
    setState(() => _index = 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _index,
                children: [
                  ReceiptsPage(categoryFilter: _filter),
                  HomePage(onOpenCategory: _openCategory),
                  const SettingsPage(),
                ],
              ),
            ),
            FloatingNav(index: _index, onTap: (i) => setState(() => _index = i)),
          ],
        ),
      ),
    );
  }
}

