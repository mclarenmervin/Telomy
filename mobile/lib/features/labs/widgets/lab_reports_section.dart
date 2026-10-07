import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/capture_advice.dart';
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
class LabReportsSection extends ConsumerStatefulWidget {
  const LabReportsSection({super.key});

  @override
  ConsumerState<LabReportsSection> createState() => _LabReportsSectionState();
}

class _LabReportsSectionState extends ConsumerState<LabReportsSection> {
  Timer? _poll;

  /// Extraction takes seconds and nothing pushes the result to the phone, so
  /// the list re-reads itself while anything is still being worked on. Without
  /// this the tile says "Reading the report..." forever and the user can never
  /// reach the confirmation screen -- which is how it behaved on a real device.
  void _pollWhileInFlight(List<LabUpload> uploads) {
    final waiting = uploads.any((u) => u.isInFlight);
    if (!waiting) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) ref.invalidate(labUploadsProvider);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uploads = ref.watch(labUploadsProvider);
    uploads.whenData(_pollWhileInFlight);

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
        const SizedBox(height: 8),
        // Said before the photo is taken rather than after it fails. The
        // straightness and framing of the picture matter more to whether we can
        // read it than anything we do afterwards.
        for (final tip in captureTips)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 2),
            child: Text('• $tip', style: theme.textTheme.bodySmall),
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
    final problems = <String>[];
    for (final file in picked) {
      final extension = extensionOf(file.name);
      final bytes = await file.readAsBytes();
      final size = await _pixelSize(bytes, extension);

      // Checked before the upload: the alternative is the user waiting through
      // an upload and an extraction to be told we could not read the text.
      final advice = adviseOnCapture(
        extension: extension,
        byteSize: bytes.length,
        width: size?.width.toInt(),
        height: size?.height.toInt(),
      );
      if (advice.isNotEmpty) {
        problems.add('${file.name}: ${advice.first}');
        continue;
      }
      files.add(LabFile(name: file.name, extension: extension, bytes: bytes));
    }

    if (problems.isNotEmpty) {
      messenger.showSnackBar(SnackBar(
        content: Text(problems.first),
        duration: const Duration(seconds: 6),
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

/// The image's real dimensions, or null when it is not an image or cannot be
/// decoded. Null is not a failure: refusing a good report because a decode went
/// wrong is worse than attempting the upload.
Future<ui.Size?> _pixelSize(List<int> bytes, String extension) async {
  if (extension.toLowerCase() == 'pdf') return null;
  try {
    final codec = await ui.instantiateImageCodec(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final size = ui.Size(image.width.toDouble(), image.height.toDouble());
    image.dispose();
    codec.dispose();
    return size;
  } catch (_) {
    return null;
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
    final messenger = ScaffoldMessenger.of(context);
    final LabReview review;
    try {
      review = await ref.read(labReviewProvider(upload.id).future);
    } catch (error) {
      // Silence here reads as a dead button: the first real device showed a
      // tile that did nothing at all when this call failed, with no way for
      // the user to know why or that anything had happened.
      messenger.showSnackBar(SnackBar(
        content: Text('We could not open this report just now. $error'),
      ));
      return;
    }
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
