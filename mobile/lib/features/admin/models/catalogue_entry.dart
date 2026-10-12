import 'package:flutter/foundation.dart';

/// One entry somebody could sign, as the admin surface sees it.
@immutable
class CatalogueEntry {
  const CatalogueEntry({
    required this.entryId,
    required this.label,
    required this.fingerprint,
    required this.signed,
    this.reviewer,
    this.reviewedAt,
  });

  final String entryId;

  /// What a clinician reads to know what they are being asked about. An id is
  /// not a thing to take a clinical view on.
  final String label;

  /// The hash a signature has to be over. Sent back with the signature, which
  /// is the client asserting which text was on the screen.
  final String fingerprint;

  final bool signed;
  final String? reviewer;
  final String? reviewedAt;

  static CatalogueEntry fromJson(Map<String, dynamic> json) => CatalogueEntry(
        entryId: json['entry_id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        fingerprint: json['fingerprint']?.toString() ?? '',
        signed: json['signed'] == true,
        reviewer: json['reviewer']?.toString(),
        reviewedAt: json['reviewed_at']?.toString(),
      );
}

@immutable
class ReviewableCatalogue {
  const ReviewableCatalogue({
    required this.name,
    required this.path,
    required this.version,
    required this.entries,
  });

  final String name;
  final String path;
  final String version;
  final List<CatalogueEntry> entries;

  int get unsigned => entries.where((e) => !e.signed).length;

  static ReviewableCatalogue fromJson(Map<String, dynamic> json) =>
      ReviewableCatalogue(
        name: json['name']?.toString() ?? '',
        path: json['path']?.toString() ?? '',
        version: json['version']?.toString() ?? '',
        entries: [
          for (final row in (json['entries'] as List?) ?? const [])
            CatalogueEntry.fromJson((row as Map).cast<String, dynamic>()),
        ],
      );
}

/// What an admin did, as the trail records it.
@immutable
class AdminAction {
  const AdminAction({
    required this.id,
    required this.actorId,
    required this.action,
    required this.createdAt,
    this.subjectKind,
    this.subjectId,
    this.detail = const {},
  });

  final String id;
  final String actorId;
  final String action;
  final DateTime? createdAt;
  final String? subjectKind;
  final String? subjectId;
  final Map<String, dynamic> detail;

  /// The action, in words a person reads rather than a column value.
  String get label => switch (action) {
        'role_granted' => 'Granted a role',
        'role_revoked' => 'Revoked a role',
        'clinician_registered' => 'Registered a clinician',
        'clinician_suspended' => 'Suspended a clinician',
        'clinician_reinstated' => 'Reinstated a clinician',
        'signoff_recorded' => 'Recorded a sign-off',
        'signoff_withdrawn' => 'Withdrew a sign-off',
        'draft_withdrawn' => 'Withdrew a draft',
        'draft_requeued' => 'Returned a draft to the queue',
        'erasure_requested' => 'Logged an erasure request',
        'erasure_completed' => 'Completed an erasure',
        'consent_viewed' => 'Read a consent record',
        // Not "Unknown". A trail that cannot name an action it is holding
        // should still show the action, because the raw value is what an
        // auditor would ask about.
        _ => action,
      };

  static AdminAction fromJson(Map<String, dynamic> json) => AdminAction(
        id: json['id']?.toString() ?? '',
        actorId: json['actor_id']?.toString() ?? '',
        action: json['action']?.toString() ?? '',
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
        subjectKind: json['subject_kind']?.toString(),
        subjectId: json['subject_id']?.toString(),
        detail: (json['detail'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}
