import 'package:flutter/material.dart';

import '../data/value_crop.dart';

/// The piece of the user's own report a value was read from.
///
/// Shown beside every extracted value, and it is the whole reason the bounding
/// box is stored. When the text came from OCR, this is the only check left:
/// `14` misread as `1.4` is a plausible haemoglobin, and nothing downstream can
/// catch it. Asking "is 1.4 right?" against someone's memory is worthless.
/// Showing them the picture is not.
///
/// It renders nothing at all rather than something wrong. A missing image or an
/// unplaceable box means the user falls back to checking the number against the
/// paper in their hand, which is still better than a crop of the wrong row.
class ValueCropView extends StatefulWidget {
  const ValueCropView({
    super.key,
    required this.imageUrl,
    required this.bbox,
    this.height = 64,
  });

  /// Short-lived signed URL for the page. Null when the object is missing.
  final String? imageUrl;
  final Map<String, dynamic>? bbox;
  final double height;

  @override
  State<ValueCropView> createState() => _ValueCropViewState();
}

class _ValueCropViewState extends State<ValueCropView> {
  /// A decode failure collapses the whole frame rather than leaving an empty
  /// bordered box. A blank picture reads as "there is nothing here to see",
  /// which is a different and wronger claim than showing no picture at all.
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    final url = widget.imageUrl;
    final crop = ValueCrop.fromBbox(widget.bbox);
    if (url == null || crop == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      height: widget.height,
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: ClipRect(
        // Align with width/height factors crops to a fraction of its child and
        // positions that window by alignment, which is exactly the operation
        // the stored box describes.
        child: Align(
          alignment: Alignment(crop.alignmentX, crop.alignmentY),
          widthFactor: crop.widthFactor,
          heightFactor: crop.heightFactor,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            // A broken image must not become a broken screen: the values are
            // still reviewable without it.
            errorBuilder: (_, _, _) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !_failed) setState(() => _failed = true);
              });
              return const SizedBox.shrink();
            },
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
