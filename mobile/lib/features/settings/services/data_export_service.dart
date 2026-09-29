import 'dart:convert';
import '../../journal/models/wellness_data.dart';

abstract interface class DataExportService {
  String createExport(WellnessData data);
}

class JsonDataExportService implements DataExportService {
  const JsonDataExportService();
  @override
  String createExport(WellnessData data) =>
      const JsonEncoder.withIndent('  ').convert({
        'format': 'telomy-personal-data',
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'data': data.toJson(),
      });
}
