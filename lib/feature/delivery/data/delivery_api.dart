import '../../location/domain/location_fix.dart';
import '../domain/delivery.dart';
import '../domain/delivery_status.dart';
import '../domain/geo.dart';

/// Why a delivery request failed. The UI maps these to copy; the server's
/// message is kept for logs and support, not shown verbatim.
enum DeliveryErrorCode {
  /// No connection, DNS failure, connection refused.
  network,
  timeout,

  /// Session missing or expired: the partner has to sign in again.
  unauthorized,
  forbidden,
  notFound,

  /// The offer expired, was cancelled or was taken by someone else.
  offerUnavailable,

  /// The delivery is no longer in a state that allows this action.
  invalidTransition,

  /// The backend's own geofence check failed.
  tooFarFromStop,
  invalidOtp,

  /// Too many wrong codes; support has to complete the delivery.
  otpLocked,
  validation,
  server,

  /// The server answered with something the app could not parse.
  invalidResponse,
  unknown,
}

class DeliveryException implements Exception {
  const DeliveryException(
    this.code, {
    this.message,
    this.retryable = false,
    this.attemptsRemaining,
    this.statusCode,
  });

  final DeliveryErrorCode code;
  final String? message;

  /// Safe to send the same request again (with the same idempotency key).
  final bool retryable;

  /// For [DeliveryErrorCode.invalidOtp].
  final int? attemptsRemaining;
  final int? statusCode;

  @override
  String toString() =>
      'DeliveryException(${code.name}${statusCode == null ? '' : ', $statusCode'}'
      '${message == null ? '' : ', $message'})';
}

enum ArrivalDetection {
  /// Confirmed by the app's geofence detector.
  auto('auto'),

  /// The partner tapped "I've arrived".
  manual('manual');

  const ArrivalDetection(this.wire);
  final String wire;
}

class ArrivalReport {
  const ArrivalReport({required this.stop, required this.detection, this.fix});

  final StopKind stop;
  final ArrivalDetection detection;

  /// Latest position, so the backend can run its own distance check.
  final LocationFix? fix;

  Map<String, dynamic> toJson() => {
    'stop': stop.wire,
    'detection': detection.wire,
    if (fix != null) 'location': locationJson(fix!),
  };
}

/// Evidence that a parcel was handed over. Validated by the backend only.
sealed class DeliveryProof {
  const DeliveryProof();

  VerificationMethod get method;
  Map<String, dynamic> toJson();
}

class OtpProof extends DeliveryProof {
  const OtpProof(this.code);

  final String code;

  @override
  VerificationMethod get method => VerificationMethod.otp;

  @override
  Map<String, dynamic> toJson() => {'method': method.wire, 'otp': code};

  // Never print the code.
  @override
  String toString() => 'OtpProof(***)';
}

/// The delivery backend, as the app needs it. `docs/delivery-api.md`
/// describes the HTTP contract that `HttpDeliveryApi` implements.
///
/// Every mutating call takes an idempotency key: sending the same key again
/// must return the original result instead of applying the change twice.
abstract class DeliveryApi {
  Future<void> setAvailability({
    required bool online,
    GeoPoint? at,
    required String idempotencyKey,
  });

  /// Pending offers for this partner. [at] doubles as a location heartbeat.
  Future<OffersResult> fetchOffers({GeoPoint? at});

  Future<Delivery> accept(String deliveryId, {required String idempotencyKey});

  Future<void> reject(
    String deliveryId, {
    String? reason,
    required String idempotencyKey,
  });

  /// The partner's current delivery, or null if there is none.
  Future<Delivery?> fetchActive();

  /// One of the partner's deliveries, in whatever state it is now.
  Future<Delivery> fetchDelivery(String deliveryId);

  Future<Delivery> reportArrival(
    String deliveryId,
    ArrivalReport report, {
    required String idempotencyKey,
  });

  Future<Delivery> confirmPickup(
    String deliveryId, {
    required String idempotencyKey,
  });

  Future<Delivery> complete(
    String deliveryId,
    DeliveryProof proof, {
    LocationFix? fix,
    required String idempotencyKey,
  });

  Future<HistoryPage> fetchHistory({String? cursor, int limit = 20});

  Future<PartnerSummary> fetchSummary();
}

Map<String, dynamic> locationJson(LocationFix fix) => {
  'lat': fix.latitude,
  'lng': fix.longitude,
  if (fix.accuracy != null) 'accuracy': fix.accuracy,
  'recordedAt': fix.timestamp.toUtc().toIso8601String(),
};
