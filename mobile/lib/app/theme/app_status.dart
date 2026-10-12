import 'package:flutter/material.dart';

import 'app_colors.dart';

/// A foreground and a soft background for one status.
@immutable
class StatusTone {
  const StatusTone({required this.foreground, required this.background});

  final Color foreground;
  final Color background;
}

/// Every state this product can say a thing is in.
///
/// Ported from the prototype's status ramp, which is a strict superset of what
/// we had — we had none of it, and each screen picked a colour.
///
/// **Every status carries a word.** `label` is not decoration and not a
/// tooltip: a colour alone fails for a colour-blind reader, fails in a
/// screenshot pasted into a clinical report, and fails in the one place this
/// matters most, which is telling a measured number from a simulated one. The
/// activity report already follows this discipline for severity; this is the
/// same rule with a token behind it.
///
/// **`simulated` is in the ramp from F9**, before anything simulated exists.
/// Decision 5 of the programme says a simulated number presented as a
/// measurement is the single worst outcome available to this work, and F13 is
/// where the temptation arrives. A phase that has to invent its own token for
/// it is a phase that might not bother.
enum AppStatus {
  optimal,
  inRange,
  outOfRange,
  riskVariant,
  typical,
  detected,
  notDetected,
  awaitingClinician,
  signed,
  rejected,
  notReviewed,
  simulated;

  /// The word. Shown next to, or instead of, the colour.
  String get label => switch (this) {
        AppStatus.optimal => 'Optimal',
        AppStatus.inRange => 'In range',
        AppStatus.outOfRange => 'Out of range',
        AppStatus.riskVariant => 'Risk variant',
        AppStatus.typical => 'Typical',
        AppStatus.detected => 'Detected',
        AppStatus.notDetected => 'Not detected',
        AppStatus.awaitingClinician => 'Awaiting clinician',
        AppStatus.signed => 'Signed',
        AppStatus.rejected => 'Rejected',
        AppStatus.notReviewed => 'Not reviewed',
        AppStatus.simulated => 'Simulated',
      };

  StatusTone tone(Brightness brightness) =>
      brightness == Brightness.light ? _light : _dark;

  StatusTone get _light => switch (this) {
        AppStatus.optimal =>
          const StatusTone(foreground: Color(0xFF1F6B45), background: Color(0xFFE4F2E9)),
        AppStatus.inRange =>
          const StatusTone(foreground: AppColors.teal, background: AppColors.tealSoft),
        AppStatus.outOfRange =>
          const StatusTone(foreground: Color(0xFFB4442E), background: Color(0xFFFBE8E3)),
        AppStatus.riskVariant =>
          const StatusTone(foreground: Color(0xFF8A4B16), background: Color(0xFFFBEEDF)),
        AppStatus.typical =>
          const StatusTone(foreground: Color(0xFF4A5A66), background: Color(0xFFECEFF2)),
        AppStatus.detected =>
          const StatusTone(foreground: Color(0xFF7A3E8F), background: Color(0xFFF3E9F6)),
        AppStatus.notDetected =>
          const StatusTone(foreground: Color(0xFF6B6B63), background: Color(0xFFF0EFEA)),
        // Waiting on a human, which is a hopeful state and must not look like
        // a failure. The queue being slow is our problem, not the user's.
        AppStatus.awaitingClinician =>
          const StatusTone(foreground: Color(0xFF1C5A77), background: Color(0xFFE3EFF5)),
        AppStatus.signed =>
          const StatusTone(foreground: Color(0xFF145C3E), background: Color(0xFFDFF0E7)),
        AppStatus.rejected =>
          const StatusTone(foreground: Color(0xFF8E3030), background: Color(0xFFF7E4E4)),
        // Deliberately quiet. "Nobody has reviewed this" is the honest default
        // state of almost everything in this product today, and a loud badge
        // on fifty screens would train people to ignore it.
        AppStatus.notReviewed =>
          const StatusTone(foreground: AppColors.inkMuted, background: Color(0xFFEFEDE7)),
        // Deliberately loud. The opposite reasoning: this one must never be
        // missed, and there should never be enough of it to become noise.
        AppStatus.simulated =>
          const StatusTone(foreground: Color(0xFF8A5A00), background: Color(0xFFFFF1D6)),
      };

  StatusTone get _dark => switch (this) {
        AppStatus.optimal =>
          const StatusTone(foreground: Color(0xFF7FCFA3), background: Color(0xFF17352A)),
        AppStatus.inRange =>
          const StatusTone(foreground: Color(0xFF6FBFA8), background: Color(0xFF14302C)),
        AppStatus.outOfRange =>
          const StatusTone(foreground: Color(0xFFF09A84), background: Color(0xFF3A211C)),
        AppStatus.riskVariant =>
          const StatusTone(foreground: Color(0xFFDBA269), background: Color(0xFF362618)),
        AppStatus.typical =>
          const StatusTone(foreground: Color(0xFFA7B6C0), background: Color(0xFF212D33)),
        AppStatus.detected =>
          const StatusTone(foreground: Color(0xFFC79BD6), background: Color(0xFF2C2033)),
        AppStatus.notDetected =>
          const StatusTone(foreground: Color(0xFFA6A69D), background: Color(0xFF262623)),
        AppStatus.awaitingClinician =>
          const StatusTone(foreground: Color(0xFF8CC3DD), background: Color(0xFF172E38)),
        AppStatus.signed =>
          const StatusTone(foreground: Color(0xFF74C79F), background: Color(0xFF123328)),
        AppStatus.rejected =>
          const StatusTone(foreground: Color(0xFFE88B8B), background: Color(0xFF351D1D)),
        AppStatus.notReviewed =>
          const StatusTone(foreground: AppColors.nightInkMuted, background: Color(0xFF202C2F)),
        AppStatus.simulated =>
          const StatusTone(foreground: Color(0xFFE7BC63), background: Color(0xFF3A2F14)),
      };
}
