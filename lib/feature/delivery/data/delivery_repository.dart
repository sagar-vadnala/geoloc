import '../../../core/ids.dart';
import '../../location/domain/location_fix.dart';
import '../domain/delivery.dart';
import '../domain/delivery_status.dart';
import '../domain/geo.dart';
import 'delivery_api.dart';

/// Front door to the delivery backend for the controllers.
///
/// * Each logical action (accept delivery X, complete X with code Y) gets
///   one idempotency key that is reused for every retry until the action
///   succeeds or fails for good. A request whose response was lost can
///   therefore be sent again without being applied twice.
/// * Transient failures (no network, timeouts, 5xx) are retried a few times
///   with backoff before the error reaches the UI, where the partner can
///   retry again with the same key.
class DeliveryRepository {
  DeliveryRepository(
    this._api, {
    String Function()? newKey,
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 3)],
    Future<void> Function(Duration)? sleep,
  }) : _newKey = newKey ?? randomId,
       _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final DeliveryApi _api;
  final String Function() _newKey;
  final Future<void> Function(Duration) _sleep;

  /// Waits between automatic retries; its length is the number of retries.
  final List<Duration> retryDelays;

  final Map<String, String> _keys = {};

  Future<void> setAvailability(bool online, {GeoPoint? at}) => _mutate(
    'availability:$online',
    (key) => _api.setAvailability(online: online, at: at, idempotencyKey: key),
  );

  Future<OffersResult> offers({GeoPoint? at}) =>
      _api.fetchOffers(at: at); // Polled anyway; no extra retries.

  Future<Delivery> accept(String id) =>
      _mutate('accept:$id', (key) => _api.accept(id, idempotencyKey: key));

  Future<void> reject(String id, {String? reason}) => _mutate(
    'reject:$id',
    (key) => _api.reject(id, reason: reason, idempotencyKey: key),
  );

  Future<Delivery?> activeDelivery() => _withRetry(_api.fetchActive);

  Future<Delivery> delivery(String id) =>
      _withRetry(() => _api.fetchDelivery(id));

  Future<Delivery> reportArrival(
    String id,
    StopKind stop, {
    required ArrivalDetection detection,
    LocationFix? fix,
  }) => _mutate(
    'arrive:$id:${stop.wire}',
    (key) => _api.reportArrival(
      id,
      ArrivalReport(stop: stop, detection: detection, fix: fix),
      idempotencyKey: key,
    ),
  );

  Future<Delivery> confirmPickup(String id) => _mutate(
    'pickup:$id',
    (key) => _api.confirmPickup(id, idempotencyKey: key),
  );

  /// The code is part of the key scope: a corrected code is a new attempt,
  /// while a retry of the same code after a dropped connection is not.
  Future<Delivery> completeWithOtp(
    String id,
    String code, {
    LocationFix? fix,
  }) => _mutate(
    'complete:$id:$code',
    (key) => _api.complete(id, OtpProof(code), fix: fix, idempotencyKey: key),
  );

  Future<HistoryPage> history({String? cursor, int limit = 20}) =>
      _withRetry(() => _api.fetchHistory(cursor: cursor, limit: limit));

  Future<PartnerSummary> summary() => _withRetry(_api.fetchSummary);

  Future<T> _mutate<T>(
    String scope,
    Future<T> Function(String key) call,
  ) async {
    final key = _keys.putIfAbsent(scope, _newKey);
    try {
      final result = await _withRetry(() => call(key));
      _keys.remove(scope);
      return result;
    } on DeliveryException catch (e) {
      // Keep the key only while the outcome is unknown.
      if (!e.retryable) _keys.remove(scope);
      rethrow;
    }
  }

  Future<T> _withRetry<T>(Future<T> Function() call) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await call();
      } on DeliveryException catch (e) {
        if (!e.retryable || attempt >= retryDelays.length) rethrow;
        await _sleep(retryDelays[attempt]);
      }
    }
  }
}
