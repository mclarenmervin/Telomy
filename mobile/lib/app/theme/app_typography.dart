import 'package:flutter/material.dart';

/// One typographic scale, which is what makes 73 screens look like one
/// product.
///
/// The prototype's `T` component takes `v="h1" | "h3" | "body" | "small" |
/// "label" | "num"` and nothing else, and every screen is built from those
/// six. Ours had three `copyWith` calls on the Material scale and every screen
/// reaching into `textTheme` for whatever looked right.
///
/// **On Fraunces.** The prototype sets Inter for UI and Fraunces as the
/// display serif. Neither is bundled here and this file deliberately does not
/// pull them at runtime: `google_fonts` fetches over the network on first
/// paint, and an offline-first health app that renders in a fallback face
/// until a request completes — or renders in it permanently on a plane — is
/// worse than one that never promised the serif. [displayFamily] is the token
/// to set once a licensed asset is in `fonts/`; until then the platform face
/// is used and the *scale* is the half that ports.
enum TextVariant { h1, h2, h3, body, small, label, num }

abstract final class AppTypography {
  /// Null until a licensed Fraunces asset is bundled. See the class comment.
  static const String? displayFamily = null;

  /// The style for one variant, resolved against the platform's base theme so
  /// that the user's own text-size setting still applies.
  static TextStyle scale(TextVariant variant, TextTheme base) =>
      switch (variant) {
        TextVariant.h1 => (base.headlineLarge ?? const TextStyle()).copyWith(
            fontFamily: displayFamily,
            fontSize: 30,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.5,
            height: 1.15,
          ),
        TextVariant.h2 => (base.headlineSmall ?? const TextStyle()).copyWith(
            fontFamily: displayFamily,
            fontSize: 23,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.3,
            height: 1.2,
          ),
        TextVariant.h3 => (base.titleMedium ?? const TextStyle()).copyWith(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
            height: 1.25,
          ),
        TextVariant.body => (base.bodyMedium ?? const TextStyle()).copyWith(
            fontSize: 15,
            height: 1.45,
          ),
        TextVariant.small => (base.bodySmall ?? const TextStyle()).copyWith(
            fontSize: 13,
            height: 1.4,
          ),
        TextVariant.label => (base.labelSmall ?? const TextStyle()).copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            height: 1.2,
          ),
        // Tabular figures, which is the whole reason `num` is a separate
        // variant rather than a bold body. Proportional digits are different
        // widths, so a number that updates in place jitters and a column of
        // them does not line up. F13's live floor refreshes every fifteen
        // seconds.
        TextVariant.num => (base.headlineMedium ?? const TextStyle()).copyWith(
            fontSize: 28,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.5,
            height: 1.1,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
      };

  /// Applied to the whole theme, so that a widget reaching into `textTheme`
  /// directly still lands on the scale rather than beside it.
  static TextTheme apply(TextTheme base) => base.copyWith(
        headlineLarge: scale(TextVariant.h1, base),
        headlineMedium: scale(TextVariant.num, base),
        headlineSmall: scale(TextVariant.h2, base),
        titleLarge: scale(TextVariant.h3, base).copyWith(fontSize: 19),
        titleMedium: scale(TextVariant.h3, base),
        titleSmall: scale(TextVariant.h3, base).copyWith(fontSize: 15),
        bodyMedium: scale(TextVariant.body, base),
        bodySmall: scale(TextVariant.small, base),
        labelSmall: scale(TextVariant.label, base),
      );
}
