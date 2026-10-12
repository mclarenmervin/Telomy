import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../data/admin_repository.dart';
import '../models/platform_health.dart';
import '../providers/admin_provider.dart';

/// What state the platform is in.
///
/// The first screen of the first role that can act on any of it, and the one
/// number it exists for is `stranded_total`: drafts flagged for a human,
/// expired, and now undeliverable — people the product noticed something
/// about and will never tell. It has been computed since F5 and logged into a
/// log nobody reads.
///
/// **Counts, not people.** No row on this screen names a member, and the
/// server would not return one if it did: 022 gives the admin role no policy
/// on any health table, and the dashboard endpoint returns numbers. "Which
/// people are behind the 41" is a question with a per-purpose consent row in
/// front of it, and F9 has nowhere to record one — so the honest state is
/// that the question cannot be asked yet rather than that it is unguarded.
class PlatformHealthScreen extends ConsumerWidget {
  const PlatformHealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(platformHealthProvider);

    return AppScreen(
      title: 'Platform',
      onRefresh: () async => ref.invalidate(platformHealthProvider),
      children: health.when(
        loading: () => [const Loading('Reading the queue and the catalogue…')],
        error: (error, _) => [
          ErrorState(
            message: error is AdminUnavailable
                ? error.message
                : 'The platform surface could not be read just now.',
            onRetry: () => ref.invalidate(platformHealthProvider),
          ),
        ],
        data: (data) => _sections(context, data),
      ),
    );
  }

  List<Widget> _sections(BuildContext context, PlatformHealth health) => [
    _QueueSection(queue: health.queue),
    const SizedBox(height: AppSpacing.xl),
    _ClinicianSection(health: health),
    const SizedBox(height: AppSpacing.xl),
    _CatalogueSection(health: health),
    const SizedBox(height: AppSpacing.xl),
    _RolesSection(roles: health.roles),
  ];
}

class _QueueSection extends StatelessWidget {
  const _QueueSection({required this.queue});

  final QueueHealth queue;

  @override
  Widget build(BuildContext context) {
    if (queue.unreadable) {
      // Explicitly not zero. A dashboard reading zero because the read failed,
      // on the screen whose job is to say people are not being told things,
      // is worse than no dashboard — so the null travels all the way here.
      return Section(
        title: 'The clinician queue',
        children: const [
          ErrorState(
            message:
                'The queue could not be read, so these numbers are '
                'unknown rather than zero.',
          ),
        ],
      );
    }

    final stranded = queue.strandedTotal ?? 0;
    return Section(
      title: 'The clinician queue',
      blurb: 'What is waiting on a human, and what has stopped waiting.',
      children: [
        AppCard(
          key: const Key('admin-stranded'),
          tone: stranded > 0 ? CardTone.copper : CardTone.plain,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stat(
                label: 'Stranded',
                value: '$stranded',
                status: stranded > 0
                    ? const StatusChip(
                        AppStatus.outOfRange,
                        label: 'Nobody will hear',
                      )
                    : const StatusChip(AppStatus.optimal, label: 'None'),
                prov: const Prov(
                  source: 'the clinician queue',
                  whenLabel: 'now',
                  confidence: Confidence.measured,
                  basis: 'flagged drafts that expired with no insight',
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              T(
                stranded > 0
                    ? 'These were flagged for a clinician, nobody reached '
                          'them in time, and they carry flags so they can never '
                          'be delivered without a signature. Each one is a '
                          'person the product noticed something about and will '
                          'not tell.'
                    : 'Nothing has expired undeliverable. Every draft either '
                          'reached a clinician or took the unreviewed route.',
                v: TextVariant.small,
                muted: true,
              ),
            ],
          ),
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppRow(label: 'Waiting on a human', value: '${queue.depth ?? 0}'),
              AppRow(
                label: 'Claimed right now',
                value: '${queue.claimed ?? 0}',
              ),
              AppRow(
                label: 'Longest past its deadline',
                value: queue.oldestWaitingHours == null
                    ? '—'
                    : '${queue.oldestWaitingHours!.toStringAsFixed(1)} h',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ClinicianSection extends StatelessWidget {
  const _ClinicianSection({required this.health});

  final PlatformHealth health;

  @override
  Widget build(BuildContext context) {
    final active = health.activeClinicians;
    return Section(
      title: 'Who can sign',
      blurb:
          'Every draft strands until somebody can. This is the number the '
          'rest of the queue depends on.',
      children: [
        if (active == null)
          const ErrorState(
            message:
                'The registrations could not be read, so this is unknown '
                'rather than none.',
          )
        else if (active == 0)
          const Empty(
            key: Key('admin-no-clinicians'),
            title: 'No clinician can sign anything',
            body:
                'Until a registered clinician with an unexpired licence '
                'joins a clinic, every draft the agent writes will expire and '
                'every reviewed-content file will stay unsigned. This is the '
                'open question the whole queue waits on.',
            tone: EmptyTone.waiting,
          )
        else
          AppCard(
            child: Stat(
              label: 'Clinicians who may sign',
              value: '$active',
              prov: const Prov(
                source: 'the registrations',
                whenLabel: 'now',
                confidence: Confidence.measured,
                basis: 'active status and an unexpired licence',
              ),
            ),
          ),
        if (health.lapsing.isNotEmpty)
          AppCard(
            key: const Key('admin-lapsing'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const T('Licences to look at', v: TextVariant.h3),
                const SizedBox(height: AppSpacing.xxs),
                const T(
                  'A lapse should be noticed here rather than discovered as a '
                  'refused signature, which is what it becomes mid-review.',
                  v: TextVariant.small,
                  muted: true,
                ),
                const SizedBox(height: AppSpacing.xs),
                for (final licence in health.lapsing)
                  ListRow(
                    title: licence.fullName,
                    subtitle: licence.registrationNumber,
                    trailing: StatusChip(
                      licence.expired
                          ? AppStatus.rejected
                          : AppStatus.awaitingClinician,
                      label: licence.expired
                          ? 'Expired'
                          : '${licence.daysLeft} days',
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CatalogueSection extends StatelessWidget {
  const _CatalogueSection({required this.health});

  final PlatformHealth health;

  @override
  Widget build(BuildContext context) => Section(
    title: 'Reviewed content',
    blurb:
        'Five files whose entries are signed one at a time against a '
        'content hash. Unsigned content stays invisible or ungraded by '
        'design, which is why the app can be complete and still show an '
        'empty biological age.',
    action: SectionAction(
      label: 'Open',
      onPressed: () => Navigator.of(context).pushNamed('/admin/catalogue'),
    ),
    children: [
      AppCard(
        key: const Key('admin-catalogue-counts'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stat(
              label: 'Entries nobody has signed',
              value: '${health.cataloguesUnsigned}',
              status: health.cataloguesUnsigned > 0
                  ? const StatusChip(AppStatus.notReviewed)
                  : const StatusChip(AppStatus.signed),
              prov: const Prov(
                source: 'the five reviewed-content files',
                whenLabel: 'this build',
                confidence: Confidence.measured,
                basis: 'per entry, bound to a content hash',
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final file in health.catalogues)
              AppRow(
                label: file.name,
                value: '${file.unsigned} of ${file.total}',
                trailing: file.unsigned == 0
                    ? const StatusChip(AppStatus.signed)
                    : null,
              ),
          ],
        ),
      ),
    ],
  );
}

class _RolesSection extends StatelessWidget {
  const _RolesSection({required this.roles});

  final Map<String, int> roles;

  @override
  Widget build(BuildContext context) => Section(
    title: 'Accounts',
    children: [
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Every role, including the ones at zero. A list that omitted
            // `centre: 0` would read as a product that does not know
            // about centres, which is a different and worse thing.
            for (final role in roles.entries)
              AppRow(label: role.key, value: '${role.value}'),
          ],
        ),
      ),
    ],
  );
}
