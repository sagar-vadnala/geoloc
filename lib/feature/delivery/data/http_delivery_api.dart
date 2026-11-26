import 'package:dio/dio.dart';

import '../../location/domain/location_fix.dart';
import '../domain/delivery.dart';
import '../domain/geo.dart';
import 'delivery_api.dart';

/// Supplies the partner's session token. Null means "not signed in".
typedef AccessTokenProvider = Future<String?> Function();

/// Adds `Authorization: Bearer <token>` and reports 401s so the app can end
/// the session.
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this._token, {this.onUnauthorized});

  final AccessTokenProvider _token;
  final void Function()? onUnauthorized;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _token();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 401) onUnauthorized?.call();
    handler.next(err);
  }
}

/// [DeliveryApi] over HTTP. The contract is in `docs/delivery-api.md`.
class HttpDeliveryApi implements DeliveryApi {
  HttpDeliveryApi(this._dio);

  final Dio _dio;

  static const idempotencyHeader = 'Idempotency-Key';

  @override
  Future<void> setAvailability({
    required bool online,
    GeoPoint? at,
    required String idempotencyKey,
  }) => _send(
    () => _dio.put<Object?>(
      '/partner/availability',
      data: {'online': online, if (at != null) 'location': at.toJson()},
      options: _mutation(idempotencyKey),
    ),
    (_) {},
  );

  @override
  Future<OffersResult> fetchOffers({GeoPoint? at}) => _send(
    () => _dio.get<Object?>(
      '/partner/offers',
      queryParameters: {
        if (at != null) 'lat': at.latitude,
        if (at != null) 'lng': at.longitude,
      },
    ),
    (data) {
      final json = _map(data);
      final pollAfter = json['pollAfterSeconds'] as num?;
      return OffersResult(
        offers: _list(json['offers']).map(DeliveryOffer.fromJson).toList(),
        pollAfter: pollAfter == null
            ? null
            : Duration(seconds: pollAfter.round()),
      );
    },
  );

  @override
  Future<Delivery> accept(
    String deliveryId, {
    required String idempotencyKey,
  }) => _send(
    () => _dio.post<Object?>(
      '/deliveries/${_id(deliveryId)}/accept',
      options: _mutation(idempotencyKey),
    ),
    _delivery,
  );

  @override
  Future<void> reject(
    String deliveryId, {
    String? reason,
    required String idempotencyKey,
  }) => _send(
    () => _dio.post<Object?>(
      '/deliveries/${_id(deliveryId)}/reject',
      data: {if (reason != null) 'reason': reason},
      options: _mutation(idempotencyKey),
    ),
    (_) {},
  );

  @override
  Future<Delivery?> fetchActive() => _send(
    () => _dio.get<Object?>('/partner/deliveries/active'),
    (data) => data == null || data == '' ? null : _delivery(data),
  );

  @override
  Future<Delivery> fetchDelivery(String deliveryId) => _send(
    () => _dio.get<Object?>('/deliveries/${_id(deliveryId)}'),
    _delivery,
  );

  @override
  Future<Delivery> reportArrival(
    String deliveryId,
    ArrivalReport report, {
    required String idempotencyKey,
  }) => _send(
    () => _dio.post<Object?>(
      '/deliveries/${_id(deliveryId)}/arrive',
      data: report.toJson(),
      options: _mutation(idempotencyKey),
    ),
    _delivery,
  );

  @override
  Future<Delivery> confirmPickup(
    String deliveryId, {
    required String idempotencyKey,
  }) => _send(
    () => _dio.post<Object?>(
      '/deliveries/${_id(deliveryId)}/pickup',
      options: _mutation(idempotencyKey),
    ),
    _delivery,
  );

  @override
  Future<Delivery> complete(
    String deliveryId,
    DeliveryProof proof, {
    LocationFix? fix,
    required String idempotencyKey,
  }) => _send(
    () => _dio.post<Object?>(
      '/deliveries/${_id(deliveryId)}/complete',
      data: {...proof.toJson(), if (fix != null) 'location': locationJson(fix)},
      options: _mutation(idempotencyKey),
    ),
    _delivery,
  );

  @override
  Future<HistoryPage> fetchHistory({String? cursor, int limit = 20}) => _send(
    () => _dio.get<Object?>(
      '/partner/deliveries',
      queryParameters: {
        'status': 'completed,cancelled',
        'limit': limit,
        if (cursor != null) 'cursor': cursor,
      },
    ),
    (data) {
      final json = _map(data);
      return HistoryPage(
        items: _list(json['items']).map(Delivery.fromJson).toList(),
        nextCursor: json['nextCursor'] as String?,
      );
    },
  );

  @override
  Future<PartnerSummary> fetchSummary() => _send(
    () => _dio.get<Object?>('/partner/summary'),
    (data) => PartnerSummary.fromJson(_map(data)),
  );

  Options _mutation(String key) => Options(headers: {idempotencyHeader: key});

  Future<T> _send<T>(
    Future<Response<Object?>> Function() request,
    T Function(Object? data) parse,
  ) async {
    final Response<Object?> response;
    try {
      response = await request();
    } on DioException catch (e) {
      throw mapDioError(e);
    }
    try {
      return parse(response.statusCode == 204 ? null : response.data);
    } on DeliveryException {
      rethrow;
    } catch (e) {
      // FormatException, TypeError from a missing/renamed field, ...
      throw DeliveryException(
        DeliveryErrorCode.invalidResponse,
        message: e.toString(),
        statusCode: response.statusCode,
      );
    }
  }

  static Delivery _delivery(Object? data) => Delivery.fromJson(_map(data));

  static Map<String, dynamic> _map(Object? data) {
    if (data is Map<String, dynamic>) return data;
    throw const FormatException('Expected a JSON object');
  }

  static Iterable<Map<String, dynamic>> _list(Object? data) =>
      (data as List? ?? const []).cast<Map<String, dynamic>>();

  static String _id(String id) => Uri.encodeComponent(id);

  /// Maps transport and HTTP errors to [DeliveryException]. Error bodies are
  /// expected as `{"error": {"code": "...", "message": "...", ...}}`.
  static DeliveryException mapDioError(DioException e) {
    if (e.type != DioExceptionType.badResponse) {
      final timeout = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.transformTimeout => true,
        _ => false,
      };
      return DeliveryException(
        timeout ? DeliveryErrorCode.timeout : DeliveryErrorCode.network,
        message: e.message,
        retryable: true,
      );
    }

    final status = e.response?.statusCode ?? 0;
    final body = e.response?.data;
    final error = body is Map && body['error'] is Map
        ? body['error'] as Map
        : null;
    final serverCode = error?['code'] as String?;
    final message = error?['message'] as String?;
    final attempts = error?['attemptsRemaining'] as int?;

    final code = switch (serverCode) {
      'offer_unavailable' ||
      'offer_expired' => DeliveryErrorCode.offerUnavailable,
      'invalid_transition' => DeliveryErrorCode.invalidTransition,
      'too_far_from_stop' => DeliveryErrorCode.tooFarFromStop,
      'invalid_otp' => DeliveryErrorCode.invalidOtp,
      'otp_locked' => DeliveryErrorCode.otpLocked,
      'validation_failed' => DeliveryErrorCode.validation,
      _ => switch (status) {
        401 => DeliveryErrorCode.unauthorized,
        403 => DeliveryErrorCode.forbidden,
        404 => DeliveryErrorCode.notFound,
        409 => DeliveryErrorCode.invalidTransition,
        410 => DeliveryErrorCode.offerUnavailable,
        422 || 400 => DeliveryErrorCode.validation,
        423 => DeliveryErrorCode.otpLocked,
        >= 500 || 408 || 429 => DeliveryErrorCode.server,
        _ => DeliveryErrorCode.unknown,
      },
    };

    return DeliveryException(
      code,
      message: message,
      statusCode: status,
      attemptsRemaining: attempts,
      retryable: status >= 500 || status == 408 || status == 429,
    );
  }
}
