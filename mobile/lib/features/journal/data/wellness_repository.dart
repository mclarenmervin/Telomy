import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/wellness_data.dart';

abstract interface class WellnessRepository {
  Future<WellnessData> load();
  Future<void> save(WellnessData data);
}

/// Encrypted platform storage, separate from authentication and scoped by UUID.
/// A database adapter can replace this document store for larger datasets.
class SecureWellnessRepository implements WellnessRepository {
  SecureWellnessRepository(this.userId, {FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final String userId;
  final FlutterSecureStorage _storage;
  String get _key => 'telomy.wellness.v1.$userId';
  @override
  Future<WellnessData> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return const WellnessData();
    return WellnessData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> save(WellnessData data) =>
      _storage.write(key: _key, value: jsonEncode(data.toJson()));
}

class SupabaseWellnessRepository implements WellnessRepository {
  SupabaseWellnessRepository(this.userId, this.client)
    : local = SecureWellnessRepository(userId);
  final String userId;
  final SupabaseClient client;
  final SecureWellnessRepository local;

  @override
  Future<WellnessData> load() async {
    final localData = await local.load();
    try {
      final normalized = await client.rpc('load_normalized_wellness');
      if (normalized is Map) {
        final remote = WellnessData.fromJson(
          Map<String, dynamic>.from(normalized),
        );
        await local.save(remote);
        return remote;
      }

      // One-time compatibility path for accounts created before the
      // normalized schema. The next call stores the document in module tables.
      final row = await client
          .from('wellness_documents')
          .select('payload')
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) {
        await _upload(localData);
        return localData;
      }
      final payload = Map<String, dynamic>.from(row['payload'] as Map);
      final remote = WellnessData.fromJson(payload);
      await _upload(remote);
      await local.save(remote);
      return remote;
    } catch (_) {
      return localData;
    }
  }

  @override
  Future<void> save(WellnessData data) async {
    await local.save(data);
    try {
      await _upload(data);
    } catch (_) {
      // Compatibility with a backend that has not received the latest
      // migration yet. Local encrypted storage remains available offline.
      try {
        await _uploadLegacy(data);
      } catch (_) {}
    }
  }

  Future<void> _upload(WellnessData data) => client.rpc(
    'save_normalized_wellness',
    params: {'payload': data.toJson()},
  );

  Future<void> _uploadLegacy(WellnessData data) =>
      client.from('wellness_documents').upsert({
        'user_id': userId,
        'payload': data.toJson(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
}
