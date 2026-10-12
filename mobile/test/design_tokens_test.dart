import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/app/theme/app_colors.dart';
import 'package:telomy/app/theme/app_status.dart';
import 'package:telomy/app/theme/app_theme.dart';
import 'package:telomy/app/theme/app_typography.dart';

/// The tokens every later phase spends.
///
/// Thin tests on purpose, and two of them earn their keep: that every status
/// in the ramp resolves in both brightnesses, and that no two statuses are the
/// same colour. A status added without a dark-mode value is invisible on half
/// the devices, and a status that collides with another is a screen that says
/// "signed" in the colour of "rejected" — neither is the kind of bug a human
/// finds by looking at a light-mode simulator.
void main() {
  group('the palette', () {
    test('teal is the prototype\'s teal, to the digit', () {
      // Both repositories cite "UI Design System v1.0" and both carry this
      // value. A port that drifted here would be visible beside the demo.
      expect(AppColors.teal, const Color(0xFF1F5C4E));
    });

    test('copper is the human counterweight to teal-as-science', () {
      expect(AppColors.copper, const Color(0xFFA9643A));
    });

    test('the canvas is Cloud Dancer', () {
      expect(AppColors.canvas, const Color(0xFFF5F3EE));
    });
  });

  group('the status ramp', () {
    test('covers every status the product can be in', () {
      expect(AppStatus.values.map((s) => s.name).toSet(), {
        'optimal',
        'inRange',
        'outOfRange',
        'riskVariant',
        'typical',
        'detected',
        'notDetected',
        'awaitingClinician',
        'signed',
        'rejected',
        'notReviewed',
        'simulated',
      });
    });

    for (final brightness in Brightness.values) {
      test('every status has a foreground and a soft background in $brightness',
          () {
        for (final status in AppStatus.values) {
          final tone = status.tone(brightness);
          expect(tone.foreground.a, 1.0, reason: '${status.name} foreground');
          expect(tone.background.a, greaterThan(0.0),
              reason: '${status.name} background');
        }
      });

      test('no two statuses share a foreground in $brightness', () {
        final seen = <Color, String>{};
        for (final status in AppStatus.values) {
          final colour = status.tone(brightness).foreground;
          expect(seen[colour], isNull,
              reason: '${status.name} is the same colour as ${seen[colour]}');
          seen[colour] = status.name;
        }
      });

      test('every status reads as text, not only as a colour, in $brightness',
          () {
        // The activity report's discipline, already in this codebase: a
        // severity is a word first. A colour alone fails for a colour-blind
        // reader and in a screenshot pasted into a report.
        for (final status in AppStatus.values) {
          expect(status.label, isNotEmpty);
          expect(status.label, isNot(status.name));
        }
      });
    }

    test('simulated is in the ramp, because decision 5 says it must be', () {
      // "A simulated number that reads as a measurement is the single worst
      // outcome available to this programme." F13 is where it is tempting;
      // the token exists from F9 so that phase has no excuse to invent one.
      expect(AppStatus.simulated.label, 'Simulated');
    });
  });

  group('the scales', () {
    test('spacing is the documented set', () {
      expect(AppSpacing.all, [4.0, 8.0, 12.0, 16.0, 20.0, 24.0, 32.0, 40.0]);
    });

    test('radii are the documented set', () {
      expect(AppRadii.all, [6.0, 10.0, 14.0, 20.0, AppRadii.pill]);
    });
  });

  group('typography', () {
    test('numbers are set with tabular figures', () {
      // A column of numbers whose digits are different widths jitters as it
      // updates, and the live floor in F13 refreshes every fifteen seconds.
      final style = AppTypography.scale(TextVariant.num, ThemeData().textTheme);
      expect(
        style.fontFeatures?.map((f) => f.feature),
        contains('tnum'),
      );
    });

    test('every variant resolves to a style with a size', () {
      final base = ThemeData().textTheme;
      for (final variant in TextVariant.values) {
        expect(AppTypography.scale(variant, base).fontSize, isNotNull,
            reason: variant.name);
      }
    });
  });

  group('the theme', () {
    for (final brightness in Brightness.values) {
      test('builds in $brightness with a scheme of that brightness', () {
        final theme = AppTheme.build(brightness);
        expect(theme.colorScheme.brightness, brightness);
        expect(theme.scaffoldBackgroundColor.a, 1.0);
      });
    }

    test('dark mode is defined rather than generated from the seed', () {
      // The prototype ships a complete dark mode and ours was whatever
      // ColorScheme.fromSeed produced. A generated dark surface put teal text
      // on a teal-tinted card at low contrast.
      final dark = AppTheme.build(Brightness.dark);
      expect(dark.scaffoldBackgroundColor, AppColors.night);
      expect(dark.colorScheme.surface, AppColors.nightSurface);
    });
  });
}
