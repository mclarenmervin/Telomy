import 'package:dio/dio.dart';

import '../models/catalogue_entry.dart';
import '../models/platform_health.dart';

/// Something stopped the admin surface being read, phrased for a person.
class AdminUnavailable implements Exception {
  const AdminUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The platform admin surface.
///
/// Everything here goes through the gateway rather than reading tables
/// directly, for one reason: the numbers are *computed*. `stranded_total` is a
/// join between expired flagged drafts and the insights that never arrived,
/// and the catalogue counts are the five YAML files' own sign-off state. A
/// phone that computed either would be a second implementation of both, and
/// the first one to drift would be the one telling us the queue is fine.
///
/// The one exception is the account list, which is an ordinary RLS-admitted
/// table read — see `AdminRolesScreen`.
class AdminRepository {
  AdminRepository({Dio? http}) : _http = http;

  final Dio? _http;

  Future<PlatformHealth> platform() async =>
      PlatformHealth.fromJson(await _get('/api/v1/admin/platform'));

  Future<List<ReviewableCatalogue>> catalogue() async {
    final body = await _get('/api/v1/admin/catalogue');
    return [
      for (final row in (body['catalogues'] as List?) ?? const [])
        ReviewableCatalogue.fromJson((row as Map).cast<String, dynamic>()),
    ];
  }

  Future<List<AdminAction>> audit() async {
    final body = await _get('/api/v1/admin/audit');
    return [
      for (final row in (body['items'] as List?) ?? const [])
        AdminAction.fromJson((row as Map).cast<String, dynamic>()),
    ];
  }

  /// The `clinical_review:` block to commit, or null when nothing is signed.
  Future<({String path, String? block, int signatures})> block(
      String catalogue) async {
    final body = await _get('/api/v1/admin/catalogue/$catalogue/block');
    return (
      path: body['path']?.toString() ?? '',
      block: body['block']?.toString(),
      signatures: (body['signatures'] as num?)?.toInt() ?? 0,
    );
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final http = _http;
    if (http == null) {
      throw const AdminUnavailable(
        'The platform surface is served by the Telomy gateway, which this '
        'build is not pointed at.',
      );
    }

    final Response<dynamic> response;
    try {
      response = await http.get(
        path,
        options: Options(
            validateStatus: (status) => status != null && status < 500),
      );
    } on DioException {
      throw const AdminUnavailable(
        'The platform surface could not be reached just now.',
      );
    }

    if (response.statusCode == 403) {
      // Said plainly rather than as a generic failure. An operator who has
      // been moved off the admin role should be told that, not left to
      // conclude the service is down.
      throw const AdminUnavailable(
        'This account is not a platform admin.',
      );
    }
    if (response.statusCode == 409) {
      throw AdminUnavailable(
        (response.data as Map?)?['detail']?.toString() ??
            'That could not be assembled.',
      );
    }
    if (response.statusCode != 200 || response.data is! Map) {
      throw const AdminUnavailable(
        'The platform surface could not be read just now.',
      );
    }
    return (response.data as Map).cast<String, dynamic>();
  }
}
