import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';
import '../../marketplace/data/marketplace_catalog.dart';

enum ConsultationStatus { upcoming, completed, cancelled }

class ConsultationService {
  const ConsultationService();
  List<JournalEntry> consultations(WellnessData data) =>
      data.entries
          .where((entry) => entry.kind == EntryKind.consultation)
          .toList()
        ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));

  ConsultationStatus status(JournalEntry entry, DateTime now) {
    final stored = entry.fields['status'];
    if (stored == 'cancelled') return ConsultationStatus.cancelled;
    if (stored == 'completed' || entry.recordedAt.isBefore(now)) {
      return ConsultationStatus.completed;
    }
    return ConsultationStatus.upcoming;
  }

  JournalEntry booking({
    required MarketplaceListing listing,
    required DateTime date,
    required String notes,
  }) => JournalEntry.create(
    kind: EntryKind.consultation,
    title: listing.name,
    recordedAt: date,
    notes: notes,
    fields: {
      'provider': listing.provider,
      'serviceId': listing.id,
      'duration': listing.duration.replaceAll(RegExp(r'[^0-9.]'), ''),
      'price': '${listing.price}',
      'delivery': listing.delivery,
      'status': 'upcoming',
    },
  );

  JournalEntry withStatus(JournalEntry entry, ConsultationStatus status) =>
      JournalEntry(
        id: entry.id,
        kind: entry.kind,
        title: entry.title,
        recordedAt: entry.recordedAt,
        notes: entry.notes,
        fields: {...entry.fields, 'status': status.name},
        parentId: entry.parentId,
      );
}
