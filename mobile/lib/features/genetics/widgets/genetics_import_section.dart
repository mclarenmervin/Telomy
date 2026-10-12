import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/genetic_upload_paths.dart';
import '../models/genetic_upload.dart';
import '../providers/genetics_provider.dart';
import 'genetics_consent.dart';

/// Importing a genetics export, and showing what survived it.
///
/// Above the free-text records on the genetics screen, because this is the
/// half that does something: the form below it has always been somewhere to
/// type the name of a lab.
class GeneticsImportSection extends ConsumerStatefulWidget {
  const GeneticsImportSection({super.key});

  @override
  ConsumerState<GeneticsImportSection> createState() =>
      _GeneticsImportSectionState();
}

class _GeneticsImportSectionState extends ConsumerState<GeneticsImportSection> {
  bool _busy = false;
  String? _error;

  Future<void> _pickAndUpload() async {
    final user = ref.read(authProvider).asData?.value;
    if (user == null) return;

    // The consent sheet opens BEFORE the picker. A confirmation that appears
    // once the file is chosen is one people click through, because by then
    // they have already decided.
    if (!await confirmGeneticsUpload(context)) return;

    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      // The bucket's MIME allowlist is plain text only, so offering anything
      // else here would only produce a failure after a 25MB upload. The .zip
      // 23andMe actually hands you is deliberately absent, and the line
      // under the button says to unzip it.
      allowedExtensions: allowedGeneticExtensions.toList(),
    );
    if (picked.isEmpty) return;
    final file = picked.first;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await file.readAsBytes();
      await ref
          .read(geneticsRepositoryProvider)
          .upload(userId: user.id, fileName: file.name, bytes: bytes);
      ref.invalidate(geneticsProvider);
    } on ArgumentError catch (error) {
      // The repository's refusals are already phrased for a person -- "unzip
      // the download first" rather than "invalid extension".
      setState(() => _error = error.message.toString());
    } catch (_) {
      setState(() => _error = 'That upload did not go through. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteEverything() async {
    final user = ref.read(authProvider).asData?.value;
    if (user == null) return;
    if (!await confirmGeneticsDeletion(context)) return;

    setState(() => _busy = true);
    try {
      await ref.read(geneticsRepositoryProvider).deleteEverything(userId: user.id);
      ref.invalidate(geneticsProvider);
    } catch (_) {
      setState(() => _error = 'That could not be deleted just now.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final view = ref.watch(geneticsProvider);

    return Column(
      key: const Key('genetics-import'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your genetics file', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Upload a 23andMe export or a VCF. We keep a short list of wellness '
          'variants and discard the rest as we read it.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (_error != null) ...[
          Card(
            key: const Key('genetics-error'),
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        ...view.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, _) => [
            TextButton(
              onPressed: () => ref.invalidate(geneticsProvider),
              child: const Text('Unable to load. Retry'),
            ),
          ],
          data: (data) => _body(context, data),
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
      ],
    );
  }

  List<Widget> _body(BuildContext context, GeneticsView view) {
    final theme = Theme.of(context);
    return [
      for (final upload in view.uploads)
        Card(
          key: Key('genetic-upload-${upload.id}'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (upload.isInFlight)
                  const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    upload.isImported
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 18,
                    color: upload.isImported
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(geneticImportSummary(upload)),
                      if (upload.fileIsGone) ...[
                        const SizedBox(height: 4),
                        Text(
                          'The file itself has been deleted.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      if (view.variants.isNotEmpty) ...[
        const SizedBox(height: 8),
        Card(
          key: const Key('genetics-variants'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What we hold', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final variant in view.variants)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('${variant.rsid} · ${variant.genotype}'),
                  ),
                const SizedBox(height: 8),
                // Said here as well as in the consent sheet, because this is
                // the screen somebody comes back to months later having
                // forgotten what they agreed to.
                Text(
                  'These appear beside a blood result when you have one for '
                  'the same thing. Nobody has reviewed what they mean yet, so '
                  'we do not say.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
        ),
      ],
      const SizedBox(height: 12),
      if (_busy)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(),
        )
      else
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('genetics-upload-button'),
                onPressed: _pickAndUpload,
                icon: const Icon(Icons.upload_file),
                label: Text(
                  view.hasAnything ? 'Upload another file' : 'Upload your file',
                ),
              ),
            ),
            if (view.hasAnything) ...[
              const SizedBox(width: 12),
              TextButton(
                key: const Key('genetics-delete-button'),
                onPressed: _deleteEverything,
                child: const Text('Delete'),
              ),
            ],
          ],
        ),
      if (!view.hasAnything) ...[
        const SizedBox(height: 10),
        Text(
          geneticsUnzipFirst,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
      Text(
        'Accepted: .txt or .vcf, up to '
        '${maxGeneticUploadBytes ~/ (1024 * 1024)}MB.',
        style:
            theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
      ),
    ];
  }
}
