import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_typography.dart';

abstract final class AppTheme {
  static ThemeData build(Brightness brightness) {
    final generated = ColorScheme.fromSeed(
      seedColor: AppColors.teal,
      brightness: brightness,
    );
    final scheme = brightness == Brightness.light
        ? generated.copyWith(
            primary: AppColors.teal,
            surface: Colors.white,
            onSurface: AppColors.ink,
            outlineVariant: const Color(0xFFE8E4DA),
            primaryContainer: const Color(0xFFE7F1EC),
          )
        : generated;
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: brightness == Brightness.light
          ? AppColors.canvas
          : AppColors.night,
      textTheme: AppTypography.apply(base.textTheme),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
