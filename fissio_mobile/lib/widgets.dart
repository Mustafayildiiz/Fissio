import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';

/// "Fissio" başlığı ve altında mor çizgi (tasarımdaki üst alan).
class FissioHeader extends StatelessWidget {
  const FissioHeader({super.key, this.title = 'Fissio', this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 30),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        Container(height: 2, color: AppColors.accent.withValues(alpha: .8)),
      ],
    );
  }
}

/// Geri butonlu sayfa başlığı ("< Fiş Oluştur").
class BackTitle extends StatelessWidget {
  const BackTitle(this.title, {super.key, this.trailing, this.circle = false});
  final String title;
  final Widget? trailing;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
      child: Row(
        children: [
          circle
              ? InkWell(
                  onTap: () => Navigator.maybePop(context),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      color: AppColors.light,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.arrow_back_ios_new,
                      size: 16,
                      color: AppColors.darkText,
                    ),
                  ),
                )
              : IconButton(
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 26),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.compact = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.accent.withValues(alpha: .5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 18 : 40,
          vertical: compact ? 10 : 14,
        ),
        textStyle: const TextStyle(fontSize: 16, fontFamily: fontFamily),
      ),
      child: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : Text(label),
    );
  }
}

/// Mor "Görüntüle" rozeti.
class ViewChip extends StatelessWidget {
  const ViewChip({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'Görüntüle',
          style: TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}

class DarkCard extends StatelessWidget {
  const DarkCard({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

class ReceiptTile extends StatelessWidget {
  const ReceiptTile({super.key, required this.expense, required this.onView});
  final Expense expense;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final name = expense.merchant.isEmpty ? 'Marka yok' : expense.merchant;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              ViewChip(onTap: onView),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFF334155),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.receipt_long,
                  size: 20,
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${fmtDate(expense.date)} - ${expense.categoryName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              Text(
                fmtMoney(expense.amount),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Alttaki yüzen gezinme çubuğu: Fişler, Ana sayfa, Ayarlar.
class FloatingNav extends StatelessWidget {
  const FloatingNav({super.key, required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  static const _icons = [Icons.receipt_long, Icons.home_outlined, Icons.settings_outlined];
  static const _labels = ['Fişler', 'Ana sayfa', 'Ayarlar'];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < 3; i++)
            Semantics(
              label: _labels[i],
              button: true,
              child: InkWell(
                onTap: () => onTap(i),
                customBorder: const CircleBorder(),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == index
                        ? AppColors.accent
                        : const Color(0xFF94A3B8),
                  ),
                  child: Icon(
                    _icons[i],
                    color: i == index ? Colors.white : AppColors.card,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return DarkCard(
      child: Row(
        children: [
          const Icon(Icons.wifi_off, color: AppColors.danger),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Tekrar dene')),
        ],
      ),
    );
  }
}

void showMessage(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

