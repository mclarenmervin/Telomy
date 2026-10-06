import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Where an uploaded report goes, and what makes two uploads the same report.
///
/// Pure, and separate from the upload itself, because these are the rules the
/// storage policies and the database depend on — not an implementation detail
/// of a button.

/// Private, size-capped and MIME-restricted on the server side.
const labReportBucket = 'lab-reports';

/// Matches `storage.buckets.file_size_limit` for this bucket. Enforced there
/// too; this copy only exists so the app can say so before spending a user's
/// data allowance on an upload that will be rejected.
const maxUploadBytes = 20 * 1024 * 1024;

/// What the bucket's `allowed_mime_types` permits.
///
/// HEIC is deliberately absent. iPhones shoot it by default and most readers
/// cannot open it, so the capture path exports JPEG instead — one line here
/// against a server-side dependency and a class of failures there.
const allowedExtensions = {'pdf', 'jpg', 'jpeg', 'png'};

/// `{user_id}/{yyyy}/{upload_id}/`
///
/// The first segment is the authorization boundary: the policies on
/// `storage.objects` compare `(storage.foldername(name))[1]` against
/// `auth.uid()`. Isolation is enforced by the storage layer rather than by our
/// code remembering to filter, and that only holds if the path is built this way.
String storagePrefixFor({
  required String userId,
  required String uploadId,
  int? year,
}) {
  final y = year ?? DateTime.now().toUtc().year;
  return '$userId/$y/$uploadId/';
}

/// One file within a report, numbered by the page it is.
///
/// The number is what `biomarker_results.page` refers to, which is what makes
/// "from page 2" and the stored bounding box mean anything.
String objectPathFor(String prefix, int pageIndex, String extension) {
  final normalised = extension.toLowerCase();
  // One spelling per format keeps paths predictable for anything that has to
  // reason about them later.
  final suffix = normalised == 'jpeg' ? 'jpg' : normalised;
  return '$prefix$pageIndex.$suffix';
}

bool isAllowedExtension(String extension) =>
    allowedExtensions.contains(extension.toLowerCase());

/// The extension of a picked file, from its name.
///
/// Derived here rather than taken from the picker: the field it exposes varies
/// between plugin versions, and the storage path depends on getting this right.
String extensionOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

bool isWithinSizeCap(int bytes) => bytes <= maxUploadBytes;

/// The digest of one file's bytes.
String fileDigest(Uint8List bytes) => sha256.convert(bytes).toString();

/// The digest of a whole report, over its files in page order.
///
/// `lab_uploads.content_sha256` is unique per user, and this is what makes that
/// constraint mean "the same report twice" rather than "the same file twice".
/// Order is part of it: provenance says "page 2", so two orderings of the same
/// photographs are two different readings of them.
String reportDigest(List<String> fileDigests) =>
    sha256.convert(fileDigests.join(':').codeUnits).toString();
