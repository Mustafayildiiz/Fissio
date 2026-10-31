import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt_detail_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.onOpenCategory});
  final ValueChanged<int> onOpenCategory;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final initial = (appState.email ?? '?').characters.first.toUpperCase();
        final highest = appState.highestExpense;
        final top = appState.topCategory;
        return Column(
          children: [
            FissioHeader(
              trailing: CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.secondaryText,
                child: Text(initial, style: const TextStyle(color: AppColors.darkText)),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: appState.refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  children: [
                    const Center(
                      child: Text(
                        'Son 1 aydaki fiş tutarı',
                        style: TextStyle(color: Colors.white, fontSize: 22),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (appState.error != null) ...[
                      ErrorBanner(appState.error!, onRetry: appState.refresh),
                      const SizedBox(height: 12),
                    ],
                    DarkCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Toplam harcama',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: AppColors.light,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Center(
                              child: Text(
                                fmtMoney(appState.lastMonthTotal),
                                style: const TextStyle(
                                  color: AppColors.darkText,
                                  fontSize: 24,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    DarkCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'En yüksek fiş tutarı',
                            style: TextStyle(color: Colors.white, fontSize: 18),
                          ),
                          const SizedBox(height: 10),
                          if (highest == null)
                            const _Empty()
                          else
                            ReceiptTile(
                              expense: highest,
                              onView: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ReceiptDetailPage(id: highest.id),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    DarkCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'En çok harcanan kategori',
                            style: TextStyle(color: Colors.white, fontSize: 18),
                          ),
                          const SizedBox(height: 10),
                          if (top == null)
                            const _Empty()
                          else
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        top.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 20,
                                        ),
                                      ),
                                      Text(
                                        fmtMoney(top.total),
                                        style: const TextStyle(
                                          color: AppColors.secondaryText,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                ViewChip(onTap: () => onOpenCategory(top.id)),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Text(
        appState.loading ? 'Yükleniyor...' : 'Son 1 ayda fiş yok.',
        style: const TextStyle(color: AppColors.secondaryText, fontSize: 13),
      );
}

