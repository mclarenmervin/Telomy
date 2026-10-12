import 'package:flutter/material.dart';

/// The palette, extended rather than replaced.
///
/// The prototype's `theme.ts` and this file both carry teal `#1F5C4E` and both
/// cite "UI Design System v1.0", so this is a token extension and not a
/// redesign. What the prototype adds and we did not have:
///
///   * **copper** as the human counterweight to teal-as-science. Teal is for
///     measurement and method; copper is for the person, their plan, the
///     things they chose. Used as a `tone` on a card, never as a status.
///   * a full status ramp with a soft background per status, in
///     [AppStatus].
///   * a complete dark mode. Ours was whatever `ColorScheme.fromSeed`
///     produced for `Brightness.dark`, which put low-contrast teal text on a
///     teal-tinted surface.
abstract final class AppColors {
  /// Science, measurement, method.
  static const teal = Color(0xFF1F5C4E);
  static const tealSoft = Color(0xFFE7F1EC);
  static const tealDeep = Color(0xFF17453A);

  /// The person. Their plan, their choices, the things they logged by hand.
  static const copper = Color(0xFFA9643A);
  static const copperSoft = Color(0xFFF6EBE3);

  static const ink = Color(0xFF1A1A18);
  static const inkMuted = Color(0xFF5E5E58);

  /// Cloud Dancer.
  static const canvas = Color(0xFFF5F3EE);
  static const line = Color(0xFFE8E4DA);

  // ── Dark mode, defined and not generated ──────────────────────────────────
  static const night = Color(0xFF101D20);
  static const nightSurface = Color(0xFF17272B);
  static const nightLine = Color(0xFF2A3C41);
  static const nightInk = Color(0xFFE8EDEC);
  static const nightInkMuted = Color(0xFF9AAAA9);
}

/// 4 · 8 · 12 · 16 · 20 · 24 · 32 · 40.
///
/// Named rather than typed inline so that "a bit more space here" is a choice
/// between two tokens instead of a number somebody picked. Every screen in the
/// prototype's 73 is built from these eight.
abstract final class AppSpacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 40.0;

  static const all = [xxs, xs, sm, md, lg, xl, xxl, xxxl];
}

/// 6 · 10 · 14 · 20 · pill.
abstract final class AppRadii {
  static const chip = 6.0;
  static const small = 10.0;
  static const card = 14.0;
  static const sheet = 20.0;

  /// Large enough that any realistic control reads as a capsule.
  static const pill = 999.0;

  static const all = [chip, small, card, sheet, pill];
}
