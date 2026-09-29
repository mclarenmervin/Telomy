import 'package:uuid/uuid.dart';

enum EntryKind {
  event,
  therapy,
  meal,
  workout,
  water,
  environment,
  genetics,
  plan,
  checkIn,
  lab,
  medication,
  medicationDose,
  consultation,
  communityPost,
  communityReply,
}

class JournalEntry {
  const JournalEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.recordedAt,
    this.notes = '',
    this.fields = const {},
    this.parentId,
  });
  factory JournalEntry.create({
    required EntryKind kind,
    required String title,
    required DateTime recordedAt,
    String notes = '',
    Map<String, String> fields = const {},
    String? parentId,
  }) => JournalEntry(
    id: const Uuid().v4(),
    kind: kind,
    title: title,
    recordedAt: recordedAt,
    notes: notes,
    fields: Map.unmodifiable(fields),
    parentId: parentId,
  );
  final String id;
  final EntryKind kind;
  final String title;
  final DateTime recordedAt;
  final String notes;
  final Map<String, String> fields;
  final String? parentId;
  double number(String key) => double.tryParse(fields[key] ?? '') ?? 0;
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'recorded_at': recordedAt.toUtc().toIso8601String(),
    'notes': notes,
    'fields': fields,
    'parent_id': parentId,
  };
  factory JournalEntry.fromJson(Map<String, dynamic> json) => JournalEntry(
    id: json['id'] as String,
    kind: EntryKind.values.byName(json['kind'] as String),
    title: json['title'] as String,
    recordedAt: DateTime.parse(json['recorded_at'] as String).toLocal(),
    notes: json['notes'] as String? ?? '',
    fields: Map<String, String>.from(json['fields'] as Map? ?? {}),
    parentId: json['parent_id'] as String?,
  );
}
