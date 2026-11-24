import 'package:dio/dio.dart';

import 'location_record.dart';

/// Server's answer for one uploaded batch.
class UploadResult {
  const UploadResult({
    this.accepted = const {},
    this.duplicates = const {},
    this.rejected = const {},
  });

  /// Stored for the first time.
  final Set<String> accepted;

  /// Already known to the server (an earlier attempt succeeded but the
  /// response was lost). Counts as synced.
  final Set<String> duplicates;

  /// Invalid records: id -> reason. Retrying will not help.
  final Map<String, String> rejected;

  factory UploadResult.fromJson(Map<String, dynamic> json) {
    List<String> ids(Object? v) =>
        (v as List? ?? const []).map((e) => e.toString()).toList();
    final rejected = <String, String>{};
    for (final item in (json['rejected'] as List? ?? const [])) {
      final m = item as Map;
      rejected[m['id'].toString()] = (m['reason'] ?? 'rejected').toString();
    }
    return UploadResult(
      accepted: ids(json['accepted']).toSet(),
      duplicates: ids(json['duplicates']).toSet(),
      rejected: rejected,
    );
  }
}

/// Failure talking to the server.
class ApiException implements Exception {
  const ApiException(this.message, {required this.retryable});

  final String message;

  /// `true` for offline / timeout / 5xx style problems (try again later),
  /// `false` when the server refused the payload itself.
  final bool retryable;

  @override
  String toString() => 'ApiException($message, retryable: $retryable)';
}

abstract class LocationApi {
  /// Uploads [records] in one request. Throws [ApiException] on failure.
  Future<UploadResult> uploadBatch(List<LocationRecord> records);
}

class DioLocationApi implements LocationApi {
  DioLocationApi(this._dio);

  final Dio _dio;

  @override
  Future<UploadResult> uploadBatch(List<LocationRecord> records) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/locations/batch',
        data: {'locations': records.map((r) => r.toApiJson()).toList()},
      );
      final body = response.data;
      if (body == null) {
        throw const ApiException('Empty response from server', retryable: true);
      }
      return UploadResult.fromJson(body);
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  static ApiException _map(DioException e) {
    if (e.type == DioExceptionType.badResponse) {
      final code = e.response?.statusCode ?? 0;
      return ApiException(
        'Server responded $code',
        retryable: _isRetryableStatus(code),
      );
    }

    // Anything else is a transport problem, not a problem with the data, so
    // the records stay pending. A default branch keeps this compiling when Dio
    // adds new exception types (5.10 added transformTimeout).
    final message = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout => 'Request timed out',
      DioExceptionType.connectionError => 'Could not reach the server',
      DioExceptionType.cancel => 'Request cancelled',
      _ => e.message ?? 'Network error',
    };
    return ApiException(message, retryable: true);
  }

  /// 5xx, 408, 425 and 429 are temporary. 401/403 mean the app is
  /// misconfigured; retrying later is better than throwing the data away.
  static bool _isRetryableStatus(int code) =>
      code >= 500 || const {401, 403, 408, 425, 429}.contains(code);
}
