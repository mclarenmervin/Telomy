import 'package:telomy/features/journal/data/wellness_repository.dart';
import 'package:telomy/features/journal/models/wellness_data.dart';

class MemoryWellnessRepository implements WellnessRepository {
  MemoryWellnessRepository([this.data = const WellnessData()]);
  WellnessData data;
  bool failSave = false;
  @override
  Future<WellnessData> load() async => WellnessData.fromJson(data.toJson());
  @override
  Future<void> save(WellnessData next) async {
    if (failSave) throw StateError('write failed');
    data = WellnessData.fromJson(next.toJson());
  }
}
