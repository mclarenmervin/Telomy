import 'package:flutter/material.dart';

abstract final class AppTypography {
  static TextTheme apply(TextTheme base) => base.copyWith(
    headlineLarge: base.headlineLarge?.copyWith(
      fontWeight: FontWeight.w500,
      letterSpacing: -0.4,
    ),
    headlineMedium: base.headlineMedium?.copyWith(
      fontWeight: FontWeight.w500,
      letterSpacing: -0.4,
    ),
    titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600),
  );
}
