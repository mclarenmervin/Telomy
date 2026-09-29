import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';

enum LabResultStatus { low, withinRange, high, rangeUnavailable }

class LabAnalysis {
  LabAnalysis(this.data);
  final WellnessData data;

  List<JournalEntry> get results =>
      data.entries.where((entry) => entry.kind == EntryKind.lab).toList()
        ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));

  LabResultStatus status(JournalEntry result) {
    final value = result.number('value');
    final low = double.tryParse(result.fields['rangeLow'] ?? '');
    final high = double.tryParse(result.fields['rangeHigh'] ?? '');
    if (low == null && high == null) return LabResultStatus.rangeUnavailable;
    if (low != null && value < low) return LabResultStatus.low;
    if (high != null && value > high) return LabResultStatus.high;
    return LabResultStatus.withinRange;
  }

  Map<String, List<JournalEntry>> get byBiomarker {
    final grouped = <String, List<JournalEntry>>{};
    for (final result in results) {
      grouped
          .putIfAbsent(result.title.trim().toLowerCase(), () => [])
          .add(result);
    }
    return grouped;
  }

  List<JournalEntry> historyFor(JournalEntry result) =>
      byBiomarker[result.title.trim().toLowerCase()] ?? const [];
}
