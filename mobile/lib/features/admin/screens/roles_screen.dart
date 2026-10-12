import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../../roles/models/app_role.dart';
import '../data/admin_repository.dart';
import '../providers/admin_provider.dart';

/// Every account and what it is on the platform.
///
/// The counts come from the dashboard endpoint. Granting a role is not on this
/// screen in F9 and that is deliberate rather than unfinished: `grant_app_role`
/// exists, files its own admin action and refuses self-elevation, but the
/// person it would be used on is an account somebody has to be able to
/// identify first — and identifying an account means reading a name and an
/// email, which is the one operational read that starts to look like a
/// profile. F10 onboards the first clinician and is where the flow around that
/// belongs.
class AdminRolesScreen extends ConsumerWidget {
  const AdminRolesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(platformHealthProvider);

    return AppScreen(
      title: 'People',
      onRefresh: () async => ref.invalidate(platformHealthProvider),
      children: health.when(
        loading: () => [const Loading('Counting the accounts…')],
        error: (error, _) => [
          ErrorState(
            message: error is AdminUnavailable
                ? error.message
                : 'The accounts could not be read just now.',
            onRetry: () => ref.invalidate(platformHealthProvider),
          ),
        ],
        data: (data) => [
          for (final role in AppRole.values)
            AppCard(
              key: Key('roles-${role.name}'),
              child: Stat(
                label: role.label,
                value: '${data.roles[role.name] ?? 0}',
                prov: const Prov(
                  source: 'profiles.app_role',
                  whenLabel: 'now',
                  confidence: Confidence.measured,
                  basis: 'the column, which every policy reads',
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          const AppCard(
            tone: CardTone.teal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                T('How a role is granted', v: TextVariant.h3),
                SizedBox(height: AppSpacing.xxs),
                T(
                  'Only through grant_app_role(), which files the record in '
                  'the same statement, refuses a non-admin actor and refuses '
                  'anybody granting themselves anything. A role written '
                  'straight into the column is refused by the database even '
                  'for us.',
                  v: TextVariant.small,
                  muted: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
