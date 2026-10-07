import 'lab_upload_paths.dart';

/// Catching an unusable photo before it is uploaded.
///
/// The alternative is the user waiting through an upload and an extraction to
/// be told "we could not read the text", by which time they have put the report
/// away. Everything checked here is knowable from the file itself, and every
/// message says what to do rather than what went wrong.
///
/// This is the part of capture-time correction that works without a native
/// document scanner. The scanner — edge detection and perspective correction at
/// the moment of capture, the way Google Drive's scan mode works — is the bigger
/// lever on OCR accuracy and needs a device build to add safely.

/// Below this, a full page of 8pt type cannot resolve at any OCR quality.
/// Phone cameras clear it easily; a cropped screenshot or a downscaled
/// WhatsApp forward often does not.
const _minPixels = 1_200_000;

/// Beyond this, the image is almost certainly a strip rather than a page.
const _maxAspect = 3.0;

/// What a good photograph of a lab report looks like. Short on purpose — nobody
/// reads a paragraph before taking a picture.
const captureTips = <String>[
  'Lay the report flat, not held in your hand.',
  'Fill the frame with the page, edge to edge.',
  'Avoid your own shadow falling across it.',
  'One photo per page, in order.',
];

/// Problems with a picked file, each phrased as an instruction.
///
/// An empty list means go ahead. Unknown image dimensions are not a problem:
/// decoding can fail for reasons that say nothing about the photo, and refusing
/// a perfectly good report is worse than attempting the upload.
List<String> adviseOnCapture({
  required String extension,
  required int byteSize,
  int? width,
  int? height,
}) {
  final advice = <String>[];
  final normalised = extension.toLowerCase();

  if (normalised == 'heic' || normalised == 'heif') {
    // The bucket's MIME allowlist rejects it, so this must be said here rather
    // than surfacing as a failed upload.
    advice.add(
      'Please share this as a JPEG. iPhones save photos as HEIC by default, '
      'which we cannot read yet — in Settings, Camera, Formats, choose '
      '"Most Compatible".',
    );
    return advice;
  }

  if (!isAllowedExtension(normalised)) {
    advice.add('Please upload a PDF or a photograph of the report.');
    return advice;
  }

  if (byteSize <= 0) {
    advice.add('Please pick the file again — this one came through empty.');
    return advice;
  }

  if (!isWithinSizeCap(byteSize)) {
    advice.add(
      'Try a smaller file — we can take up to 20MB per page.',
    );
    return advice;
  }

  // A PDF carries text or vector content, so its pixel dimensions mean nothing.
  if (normalised == 'pdf') return advice;

  if (width != null && height != null && width > 0 && height > 0) {
    if (width * height < _minPixels) {
      advice.add(
        'Take the photo closer, or from your camera rather than a forwarded '
        'copy — this one is too small for us to read the print.',
      );
    }
    final aspect = width > height ? width / height : height / width;
    if (aspect > _maxAspect) {
      advice.add('Try to capture the whole page in one photo.');
    }
  }

  return advice;
}
