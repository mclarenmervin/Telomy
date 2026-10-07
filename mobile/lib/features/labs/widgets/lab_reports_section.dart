import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/lab_repository.dart';
import '../data/lab_upload_paths.dart';
import '../models/lab_upload.dart';
import '../providers/lab_provider.dart';
import '../screens/lab_confirmation_screen.dart';

/// Uploaded reports, and the way in to confirming one.
///
/// A report sitting at `extracted` is the only actionable state, and it is the
/// one the user has to be led to: until they confirm it, nothing we read counts
/// towards anything.
class LabReportsSection extends ConsumerWidget {
  const LabReportsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final uploads = ref.watch(labUploadsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Report uploads', style: theme.textTheme.titleMedium),
            TextButton.icon(
              icon: const Icon(Icons.upload_file, size: 18),
              label: const Text('Upload'),
              onPressed: () => _pickAndUpload(context, ref),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Upload a lab report and we will read the values for you to check.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        uploads.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          ),
          // "We could not look" is not "you have none", so the failure says so.
          error: (_, _) => const Text('We could not load your reports just now.'),
          data: (list) => list.isEmpty
              ? const Text('No reports uploaded yet.')
              : Column(
                  children: [
                    for (final upload in list) _UploadTile(upload: upload),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _pickAndUpload(BuildContext context, WidgetRef ref) async {
    final user = ref.read(authProvider).asData?.value;
    if (user == null) return;

    // Captured before any await: the context must not be used across one.
    final messenger = ScaffoldMessenger.of(context);

    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      // HEIC is deliberately absent: the bucket rejects it, so offering it
      // would only produce a failure after the upload.
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
    );
    if (picked.isEmpty) return;

    final files = <LabFile>[];
    for (final file in picked) {
      files.add(LabFile(
        name: file.name,
        extension: extensionOf(file.name),
        bytes: await file.readAsBytes(),
      ));
    }
    if (files.isEmpty) return;

    try {
      await ref.read(labRepositoryProvider).upload(userId: user.id, files: files);
      ref.invalidate(labUploadsProvider);
      messenger.showSnackBar(const SnackBar(
        content: Text('Uploaded. We are reading it now — we will ask you to check it.'),
      ));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class _UploadTile extends ConsumerWidget {
  const _UploadTile({required this.upload});

  final LabUpload upload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitle = switch (upload.status) {
      'uploaded' || 'extracting' => 'Reading the report…',
      'extracted' => 'Tap to check the values we read',
      'confirmed' => upload.collectedAt == null
          ? 'Added to your record'
          : 'Collected ${DateFormat.yMMMd().format(upload.collectedAt!)}',
      'needs_password' => 'This report is password protected — tap to unlock',
      _ => upload.error ?? 'We could not read this report',
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(upload.labName ?? 'Lab report'),
        subtitle: Text(subtitle),
        trailing: upload.isAwaitingConfirmation
            ? const Icon(Icons.chevron_right)
            : null,
        onTap: upload.isAwaitingConfirmation
            ? () => _openConfirmation(context, ref)
            : null,
      ),
    );
  }

  Future<void> _openConfirmation(BuildContext context, WidgetRef ref) async {
    final review = await ref.read(labReviewProvider(upload.id).future);
    if (!context.mounted) return;

    final confirmed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LabConfirmationScreen(
          // The server's view wins: it carries the grade and the page URLs.
          upload: review.upload,
          results: review.results,
          pageUrls: review.pageUrls,
          onSubmit: (draft) => ref
              .read(labRepositoryProvider)
              .confirm(uploadId: upload.id, draft: draft),
        ),
      ),
    );
    if (confirmed == true) {
      ref.invalidate(labUploadsProvider);
      ref.invalidate(labReviewProvider(upload.id));
    }
  }
}
