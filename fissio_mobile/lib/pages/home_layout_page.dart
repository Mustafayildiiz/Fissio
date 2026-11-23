import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';
import '../theme_controller.dart';
import '../widgets.dart';

/// "Özet Görünümünü Özelleştir": ana sayfadaki kartları aç/kapat ve sırala. Tercihler yalnızca bu cihazda saklanır
/// ([ThemeController.homeCardOrder] / [ThemeController.hiddenHomeCards]). Sürükleme tutamacına ek olarak yukarı/aşağı
/// düğmeleri vardır (erişilebilirlik ve sürüklemesi zor cihazlar için).
class HomeLayoutPage extends StatelessWidget {
  const HomeLayoutPage({super.key, this.controller});

  /// Testlerde enjekte edilir; varsayılan global [themeController].
  final ThemeController? controller;

  ThemeController get _ctl => controller ?? themeController;

  void _move(int from, int to) {
    final order = List.of(_ctl.homeCardOrder);
    if (to < 0 || to >= order.length) return;
    final card = order.removeAt(from);
    order.insert(to, card);
    _ctl.setHomeCardOrder(order);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _ctl,
          builder: (context, _) {
            final order = _ctl.homeCardOrder;
            final isDefault =
                _ctl.hiddenHomeCards.isEmpty && [for (final k in order) k].toString() == HomeCard.values.toString();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const NavBackBar(label: 'Tercihler'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text('Özet görünümü', style: FissioText.title(c)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Text(
                    'Özet ekranındaki kartları aç/kapat ve sürükleyerek ya da okları kullanarak sırala. '
                    'Toplam harcama her zaman en üstte kalır.',
                    style: FissioText.body(c, size: 14, color: c.mute).copyWith(height: 1.4),
                  ),
                ),
                Expanded(
                  child: ReorderableListView(
                    key: const ValueKey('home-layout-list'),
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                    buildDefaultDragHandles: false,
                    onReorderItem: (from, to) => _move(from, to),
                    footer: isDefault
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: TextButton(
                              key: const ValueKey('home-layout-reset'),
                              onPressed: _ctl.resetHomeCards,
                              child: Text('Varsayılana döndür', style: TextStyle(color: c.accentInk)),
                            ),
                          ),
                    children: [
                      for (var i = 0; i < order.length; i++)
                        _CardRow(
                          key: ValueKey('home-layout-card-${order[i].name}'),
                          card: order[i],
                          index: i,
                          last: i == order.length - 1,
                          hidden: _ctl.hiddenHomeCards.contains(order[i]),
                          onToggle: (v) => _ctl.setHomeCardHidden(order[i], !v),
                          onMove: (delta) => _move(i, i + delta),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CardRow extends StatelessWidget {
  const _CardRow({
    super.key,
    required this.card,
    required this.index,
    required this.last,
    required this.hidden,
    required this.onToggle,
    required this.onMove,
  });

  final HomeCard card;
  final int index;
  final bool last;
  final bool hidden;
  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final name = card.name;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: c.surf,
        borderRadius: BorderRadius.circular(kRadiusSm),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(LucideIcons.gripVertical, size: 18, color: c.mute),
                ),
              ),
              Expanded(
                child: Text(
                  card.label,
                  style: FissioText.body(c, size: 16, color: hidden ? c.mute : c.ink),
                ),
              ),
              IconButton(
                key: ValueKey('home-layout-up-$name'),
                tooltip: 'Yukarı taşı',
                visualDensity: VisualDensity.compact,
                onPressed: index == 0 ? null : () => onMove(-1),
                icon: const Icon(LucideIcons.chevronUp, size: 18),
              ),
              IconButton(
                key: ValueKey('home-layout-down-$name'),
                tooltip: 'Aşağı taşı',
                visualDensity: VisualDensity.compact,
                onPressed: last ? null : () => onMove(1),
                icon: const Icon(LucideIcons.chevronDown, size: 18),
              ),
              Switch(
                key: ValueKey('home-layout-switch-$name'),
                value: !hidden,
                onChanged: onToggle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
