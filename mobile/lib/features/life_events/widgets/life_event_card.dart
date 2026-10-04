import 'package:flutter/material.dart';

import '../models/life_event.dart';
import '../providers/life_event_state.dart';

/// The event card's rendering, with no provider attached.
///
/// Split from the connected widget so every state — idle, running, waiting,
/// checked-in, escalating, failed — is reachable in a widget test without a
/// Supabase client.
class LifeEventCardBody extends StatelessWidget {
  const LifeEventCardBody({
    super.key,
    required this.state,
    required this.onStart,
    required this.onStop,
  });

  final LifeEventState state;
  final void Function(LifeEventType type) onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    state.isRunning ? 'In progress' : 'What are you doing?',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              state.isRunning
                  ? 'We’ll tell you if something changes while it happens.'
                  : 'Log it and we’ll watch what it does to your body.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (state.isRunning)
              _Running(state: state, onStop: onStop)
            else
              _Picker(busy: state.busy, onStart: onStart),
            if (state.analysis != null && !state.isRunning) ...[
              const SizedBox(height: 16),
              _Message(
                icon: Icons.summarize_outlined,
                title: 'How it went',
                body: state.analysis!.summary,
              ),
            ],
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.error!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Picker extends StatelessWidget {
  const _Picker({required this.busy, required this.onStart});

  final bool busy;
  final void Function(LifeEventType type) onStart;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final type in LifeEventType.all)
          ActionChip(
            avatar: Icon(type.icon, size: 18),
            label: Text(type.label),
            tooltip: type.blurb,
            onPressed: busy ? null : () => onStart(type),
          ),
      ],
    );
  }
}

class _Running extends StatelessWidget {
  const _Running({required this.state, required this.onStop});

  final LifeEventState state;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final event = state.event!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(event.icon, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(event.label, style: theme.textTheme.titleMedium),
                  Text(
                    _elapsedLabel(event.elapsed()),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              onPressed: state.busy ? null : onStop,
              child: const Text('Stop'),
            ),
          ],
        ),
        if (state.checkIns.isEmpty) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  state.acknowledged
                      // Deliberately not "everything looks fine": the agent has
                      // not said that, and silence is not a clean bill of health.
                      ? 'Watching your readings. We’ll speak up only if something stands out.'
                      : 'Starting to watch your readings…',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
        for (final checkIn in state.checkIns) ...[
          const SizedBox(height: 14),
          _Message(
            icon: checkIn.needsEscalation
                ? Icons.priority_high
                : Icons.favorite_outline,
            title: 'Right now',
            body: checkIn.summary,
            // The deterministic guardrail decided this; say it in words rather
            // than relying on a colour nobody has been taught to read.
            footer: checkIn.needsEscalation
                ? 'If you feel unwell, seek medical care.'
                : null,
            emphasise: checkIn.needsEscalation,
          ),
        ],
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.footer,
    this.emphasise = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? footer;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = emphasise
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.primaryContainer;
    final onTint = emphasise
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onPrimaryContainer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: onTint),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.labelLarge?.copyWith(color: onTint),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: onTint)),
          if (footer != null) ...[
            const SizedBox(height: 8),
            Text(
              footer!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: onTint,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _elapsedLabel(Duration elapsed) {
  if (elapsed.isNegative) return 'just started';
  final minutes = elapsed.inMinutes;
  if (minutes < 1) return 'just started';
  if (minutes < 60) return 'running $minutes min';
  final hours = elapsed.inHours;
  final rest = minutes - hours * 60;
  return rest == 0 ? 'running ${hours}h' : 'running ${hours}h ${rest}min';
}
