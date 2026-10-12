import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../data/admin_repository.dart';
import '../models/catalogue_entry.dart';
import '../providers/admin_provider.dart';

/// Everything in this product that is waiting for a clinician's name.
///
/// Five files, fifty entries, nothing signed. The sentences that follow from
/// that are already on real screens — "Nobody has reviewed why these two are
/// related", "Nobody has reviewed what they mean yet", an empty biological age
/// — and four of the six were added in the last two phases.
///
/// **What this screen is for, and what it cannot do.** It shows what is
/// waiting and it hands over the exact YAML to commit once something is
/// signed. It does not produce the signatory: that is the question open since
/// F6 and no interface can answer it. What it removes is the excuse — until
/// now there was nowhere for a signature to be made at all.
///
/// **An admin cannot sign here.** The signing control is absent for an admin
/// and the server refuses it independently: the signoff route admits `doctor`
/// only. An admin filing a signature in a clinician's name produces nothing
/// worth collecting, which is the whole reason the surface exists.
class AdminCatalogueScreen extends ConsumerWidget {
  const AdminCatalogueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogue = ref.watch(catalogueProvider);

    return AppScreen(
      title: 'Reviewed content',
      onRefresh: () async => ref.invalidate(catalogueProvider),
      children: catalogue.when(
        loading: () => [const Loading('Reading the five catalogues…')],
        error: (error, _) => [
          ErrorState(
            message: error is AdminUnavailable
                ? error.message
                : 'The catalogues could not be read just now.',
            onRetry: () => ref.invalidate(catalogueProvider),
          ),
        ],
        data: (files) => [
          const T(
            'Each entry is signed on its own, against a hash of its whole '
            'content — the ranges, the units, the citation. Editing any of '
            'them afterwards withdraws the signature automatically, in the '
            'same commit as the edit.',
            v: TextVariant.small,
            muted: true,
          ),
          const SizedBox(height: AppSpacing.md),
          for (final file in files) _CatalogueCard(file: file),
        ],
      ),
    );
  }
}

class _CatalogueCard extends ConsumerWidget {
  const _CatalogueCard({required this.file});

  final ReviewableCatalogue file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signed = file.entries.length - file.unsigned;

    return AppCard(
      key: Key('catalogue-${file.name}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: T(file.name, v: TextVariant.h3)),
              StatusChip(
                file.unsigned == 0 ? AppStatus.signed : AppStatus.notReviewed,
                label: file.unsigned == 0
                    ? 'All $signed signed'
                    : '${file.unsigned} unsigned',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xxs),
          // The path, because the last step of collecting a signature is a
          // human committing a file and they have to be told which one.
          T('${file.path} · ${file.version}', v: TextVariant.small, muted: true),
          const SizedBox(height: AppSpacing.xs),
          ExpansionTile(
            key: Key('catalogue-${file.name}-entries'),
            tilePadding: EdgeInsets.zero,
            title: T('${file.entries.length} entries', v: TextVariant.small),
            childrenPadding: const EdgeInsets.only(bottom: AppSpacing.xs),
            children: [
              for (final entry in file.entries)
                _EntryRow(catalogue: file.name, entry: entry),
            ],
          ),
          if (signed > 0) _BlockButton(catalogue: file.name),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.catalogue, required this.entry});

  final String catalogue;
  final CatalogueEntry entry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: T(entry.label, v: TextVariant.small)),
                if (entry.signed)
                  const StatusChip(AppStatus.signed)
                else
                  const StatusChip(AppStatus.notReviewed),
              ],
            ),
            T(
              entry.signed
                  ? '${entry.entryId} · signed by ${entry.reviewer} '
                      'on ${entry.reviewedAt}'
                  // The first twelve characters of the hash, which is enough
                  // to tell two versions of an entry apart by eye and short
                  // enough to sit in a list.
                  : '${entry.entryId} · ${entry.fingerprint.substring(0, 12)}…',
              v: TextVariant.label,
              muted: true,
            ),
          ],
        ),
      );
}

/// Hands over the block to commit.
///
/// A copy button rather than a write, deliberately. git stays the source of
/// truth for reviewed content: that is what keeps the loaders free of a
/// database call, keeps `lru_cache` on every catalog loader sound, and keeps
/// the audit trail in the diff — the git diff shows the range changed and the
/// loader stops trusting the signature in the same commit.
class _BlockButton extends ConsumerStatefulWidget {
  const _BlockButton({required this.catalogue});

  final String catalogue;

  @override
  ConsumerState<_BlockButton> createState() => _BlockButtonState();
}

class _BlockButtonState extends ConsumerState<_BlockButton> {
  bool _busy = false;
  String? _error;

  Future<void> _copy() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result =
          await ref.read(adminRepositoryProvider).block(widget.catalogue);
      if (result.block == null) {
        setState(() => _error =
            'Nothing is signed in this file, so there is no block to commit.');
        return;
      }
      await Clipboard.setData(ClipboardData(text: result.block!));
      if (mounted) {
        showToast(context, 'Block copied — commit it into ${result.path}');
      }
    } on AdminUnavailable catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_busy)
            const Loading('Assembling the block…')
          else
            TextButton.icon(
              key: Key('catalogue-${widget.catalogue}-block'),
              onPressed: _copy,
              icon: const Icon(Icons.content_copy_outlined, size: 16),
              label: const Text('Copy the block to commit'),
            ),
          if (_error != null) ErrorState(message: _error!),
        ],
      );
}
