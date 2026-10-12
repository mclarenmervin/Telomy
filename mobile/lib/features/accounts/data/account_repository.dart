import 'package:dio/dio.dart';
import '../models/account_invitation.dart';

class AccountUnavailable implements Exception {
  const AccountUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class AccountRepository {
  AccountRepository({required Dio http}) : _http = http;
  final Dio _http;
  Future<List<AccountInvitation>> pending() async {
    final data = await _request('GET', '/api/v1/invitations/pending');
    if (data is! List) {
      throw const AccountUnavailable('Invitations could not be read just now.');
    }
    return [
      for (final row in data)
        AccountInvitation.fromJson((row as Map).cast<String, dynamic>()),
    ];
  }

  Future<AccountInvitation> accept(String id) => _decision(id, 'accept');
  Future<AccountInvitation> decline(String id) => _decision(id, 'decline');
  Future<AccountInvitation> _decision(String id, String action) async {
    final data = await _request('POST', '/api/v1/invitations/$id/$action');
    if (data is! Map) {
      throw const AccountUnavailable('That invitation could not be updated.');
    }
    return AccountInvitation.fromJson(data.cast<String, dynamic>());
  }

  Future<dynamic> _request(String method, String path) async {
    try {
      final response = await _http.request<dynamic>(
        path,
        options: Options(
          method: method,
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      if (response.statusCode == 403) {
        throw const AccountUnavailable(
          'This invitation belongs to another account.',
        );
      }
      if (response.statusCode == 409) {
        throw const AccountUnavailable(
          'This invitation is no longer available.',
        );
      }
      if ((response.statusCode ?? 500) >= 400) {
        throw const AccountUnavailable(
          'Invitations are temporarily unavailable.',
        );
      }
      return response.data;
    } on AccountUnavailable {
      rethrow;
    } on DioException {
      throw const AccountUnavailable(
        'Invitations are temporarily unavailable.',
      );
    }
  }
}
