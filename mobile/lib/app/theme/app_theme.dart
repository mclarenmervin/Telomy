import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_typography.dart';

abstract final class AppTheme {
  static ThemeData build(Brightness brightness) {
    final light = brightness == Brightness.light;
    final generated = ColorScheme.fromSeed(
      seedColor: AppColors.teal,
      brightness: brightness,
    );

    // Dark mode is defined rather than left to the seed. What
    // `ColorScheme.fromSeed` produced for `Brightness.dark` was a teal-tinted
    // surface with teal-ish text on it, which is legible in a simulator and
    // not on a phone at night — and the prototype ships a complete dark mode,
    // so there is a reference for what it should be.
    final scheme = light
        ? generated.copyWith(
            primary: AppColors.teal,
            onPrimary: Colors.white,
            primaryContainer: AppColors.tealSoft,
            onPrimaryContainer: AppColors.tealDeep,
            secondary: AppColors.copper,
            secondaryContainer: AppColors.copperSoft,
            surface: Colors.white,
            onSurface: AppColors.ink,
            onSurfaceVariant: AppColors.inkMuted,
            outline: AppColors.inkMuted,
            outlineVariant: AppColors.line,
          )
        : generated.copyWith(
            primary: const Color(0xFF6FBFA8),
            onPrimary: const Color(0xFF07231D),
            primaryContainer: const Color(0xFF14302C),
            onPrimaryContainer: const Color(0xFFBCE6DA),
            secondary: const Color(0xFFD08E62),
            secondaryContainer: const Color(0xFF36261A),
            surface: AppColors.nightSurface,
            onSurface: AppColors.nightInk,
            onSurfaceVariant: AppColors.nightInkMuted,
            outline: AppColors.nightInkMuted,
            outlineVariant: AppColors.nightLine,
          );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: light ? AppColors.canvas : AppColors.night,
      textTheme: AppTypography.apply(base.textTheme),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: AppSpacing.xl,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.small),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.small),
          ),
        ),
      ),
    );
  }
}
