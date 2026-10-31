import 'package:flutter/material.dart';

class AppColors {
  static const background = Color(0xFF0F172A);
  static const card = Color(0xFF1E293B);
  static const accent = Color(0xFF7C4DFF);
  static const light = Color(0xFFF5F7FA);
  static const darkText = Color(0xFF172033);
  static const secondaryText = Color(0xFFCBD5E1);
  static const border = Color(0x1AFFFFFF);
  static const danger = Color(0xFFFF6B6B);
}

const fontFamily = 'RoundedMplus1c';

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    surface: AppColors.card,
    onSurface: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: fontFamily, // Yalnızca Bold (700) dosyası kayıtlı: tüm metinler Bold.
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.card,
    dialogTheme: const DialogThemeData(backgroundColor: AppColors.card),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.light,
      contentTextStyle: const TextStyle(
        fontFamily: fontFamily,
        color: AppColors.darkText,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

InputDecoration lightField(String label, {String? hint, Widget? suffix}) {
  OutlineInputBorder b(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c, width: 1.2),
      );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    suffixIcon: suffix,
    filled: true,
    fillColor: AppColors.light,
    floatingLabelBehavior: FloatingLabelBehavior.always,
    labelStyle: const TextStyle(color: AppColors.darkText, fontSize: 13),
    hintStyle: const TextStyle(color: Color(0xFF64748B)),
    border: b(AppColors.darkText),
    enabledBorder: b(AppColors.darkText),
    focusedBorder: b(AppColors.accent),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  );
}

String fmtMoney(double v) {
  final fixed = v.toStringAsFixed(2);
  final parts = fixed.split('.');
  final intPart = parts[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => '.',
  );
  return '$intPart,${parts[1]} ₺';
}

String fmtDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

