import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../data/admin_repository.dart';
import '../providers/admin_provider.dart';

/// What admins have done.
///
/// Including the admin reading it. There is no "except mine" filter here or in
/// the policy behind it, and there must never be one: a trail an actor can
/// exclude themselves from answers nothing in the dispute it exists for. The
/// table is append-only in Postgres, enforced by a trigger as well as by the
/// absence of an update policy, so what is on this screen is what happened.
class AdminAuditScreen extends ConsumerWidget {
  const AdminAuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audit = ref.watch(auditProvider);

    return AppScreen(
      title: 'Audit',
      onRefresh: () async => ref.invalidate(auditProvider),
      children: audit.when(
        loading: () => [const Loading('Reading the admin trail…')],
        error: (error, _) => [
          ErrorState(
            message: error is AdminUnavailable
                ? error.message
                : 'The trail could not be read just now.',
            onRetry: () => ref.invalidate(auditProvider),
          ),
        ],
        data: (items) => items.isEmpty
            ? [
                const Empty(
                  key: Key('audit-empty'),
                  title: 'Nothing has been done yet',
                  body:
                      'Granting a role, recording a sign-off, withdrawing a '
                      'draft or honouring an erasure request all appear here, '
                      'including the ones you do yourself. Nothing on this '
                      'screen can be edited or deleted by anybody.',
                  tone: EmptyTone.waiting,
                ),
              ]
            : [
                const T(
                  'Append-only, and it includes your own actions.',
                  v: TextVariant.small,
                  muted: true,
                ),
                const SizedBox(height: AppSpacing.sm),
                for (final action in items)
                  AppCard(
                    key: Key('audit-${action.id}'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: T(action.label, v: TextVariant.h3)),
                            if (action.createdAt != null)
                              T(
                                DateFormat(
                                  'd MMM, HH:mm',
                                ).format(action.createdAt!.toLocal()),
                                v: TextVariant.small,
                                muted: true,
                              ),
                          ],
                        ),
                        if (action.subjectId != null) ...[
                          const SizedBox(height: AppSpacing.xxs),
                          T(
                            '${action.subjectKind}: ${action.subjectId}',
                            v: TextVariant.small,
                            muted: true,
                          ),
                        ],
                        if (action.detail.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xxs),
                          T(
                            action.detail.entries
                                .map((e) => '${e.key}: ${e.value}')
                                .join(' · '),
                            v: TextVariant.small,
                            muted: true,
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
      ),
    );
  }
}
