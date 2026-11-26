import 'dart:math';

import '../../../location/domain/location_fix.dart';
import '../../domain/delivery.dart';
import '../../domain/delivery_status.dart';
import '../../domain/geo.dart';
import '../delivery_api.dart';

/// An in-memory stand-in for the delivery backend, used when
/// `DELIVERY_API_MODE=mock` (the default until a backend exists).
///
/// It is a development tool, not backend logic to copy: it exists so the app
/// can be run and demoed end to end. It enforces the same contract the real
/// API must (see `docs/delivery-api.md`): the state machine, idempotency
/// keys, offer expiry, server-side OTP checks with an attempt limit and a
/// distance check on arrival. With [failureRate] > 0 some calls fail with a
/// network error, half of them after the change was applied, to exercise
/// the app's retry and idempotency handling.
class MockDeliveryApi implements DeliveryApi {
  MockDeliveryApi({
    Random? random,
    DateTime Function()? now,
    this.latency = const Duration(milliseconds: 400),
    this.failureRate = 0,
    this.fallbackCenter = const GeoPoint(28.6139, 77.2090),
    this.offerLifetime = const Duration(seconds: 45),
    this.firstOfferDelay = const Duration(seconds: 3),
    this.offerGap = const Duration(seconds: 20),
    this.maxOtpAttempts = 5,
    bool seedHistory = true,
  }) : _random = random ?? Random(),
       _now = now ?? DateTime.now {
    if (seedHistory) _seedHistory();
  }

  final Duration latency;
  final double failureRate;
  final GeoPoint fallbackCenter;
  final Duration offerLifetime;
  final Duration firstOfferDelay;
  final Duration offerGap;
  final int maxOtpAttempts;

  final Random _random;
  final DateTime Function() _now;
  final Map<String, _Record> _records = {};
  final Map<String, Object> _replies = {};
  bool _online = false;
  GeoPoint? _center;
  DateTime? _nextOfferAt;
  int _sequence = 48200;
  bool? _failNext;

  /// The code the recipient would have received by SMS. Exposed only so the
  /// demo can show it; a real app never sees it.
  String? debugOtp(String deliveryId) => _records[deliveryId]?.otp;

  /// Simulates dispatch cancelling a delivery.
  void debugCancel(
    String deliveryId, {
    String reason = 'Cancelled by dispatch',
  }) {
    final record = _records[deliveryId];
    if (record == null || record.delivery.status.isTerminal) return;
    record.update(status: DeliveryStatus.cancelled, cancelReason: reason);
  }

  /// Makes the next call fail with a network error. With [responseLost] the
  /// change is applied first, as when a response never reaches the phone.
  void debugFailNextCall({bool responseLost = false}) =>
      _failNext = responseLost;

  /// Puts an offer in the queue right away (tests and demos).
  String debugCreateOffer({GeoPoint? near}) =>
      _createOffer(near ?? _center ?? fallbackCenter).delivery.id;

  @override
  Future<void> setAvailability({
    required bool online,
    GeoPoint? at,
    required String idempotencyKey,
  }) => _call(key: idempotencyKey, () {
    _online = online;
    if (at != null) _center = at;
    if (online) {
      _nextOfferAt = _now().add(firstOfferDelay);
    } else {
      // Offers waiting for this partner go back to dispatch.
      for (final record in _pendingOffers) {
        record.update(status: DeliveryStatus.expired);
      }
    }
  });

  @override
  Future<OffersResult> fetchOffers({GeoPoint? at}) => _call(() {
    if (at != null) _center = at;
    _expireStale();
    if (_online && _active == null) {
      final next = _nextOfferAt;
      if (_pendingOffers.length < 2 &&
          (next == null || !_now().isBefore(next))) {
        _createOffer(_center ?? fallbackCenter);
        final jitter = Duration(seconds: _random.nextInt(10));
        _nextOfferAt = _now().add(offerGap + jitter);
      }
    }
    return OffersResult(
      offers: _pendingOffers.map(_offerView).toList(),
      pollAfter: const Duration(seconds: 5),
    );
  });

  @override
  Future<Delivery> accept(
    String deliveryId, {
    required String idempotencyKey,
  }) => _call(key: idempotencyKey, () {
    final record = _find(deliveryId);
    _expireStale();
    final status = record.delivery.status;
    if (status == DeliveryStatus.expired ||
        status == DeliveryStatus.cancelled) {
      throw const DeliveryException(
        DeliveryErrorCode.offerUnavailable,
        message: 'Offer is no longer available',
        statusCode: 409,
      );
    }
    _transition(record, DeliveryAction.accept);
    if (_active != null) {
      throw const DeliveryException(
        DeliveryErrorCode.invalidTransition,
        message: 'Partner already has an active delivery',
        statusCode: 409,
      );
    }
    record.update(status: DeliveryStatus.accepted, acceptedAt: _now());
    // Other offers are withdrawn once the partner is busy.
    for (final other in _pendingOffers) {
      other.update(status: DeliveryStatus.expired);
    }
    return record.delivery;
  });

  @override
  Future<void> reject(
    String deliveryId, {
    String? reason,
    required String idempotencyKey,
  }) => _call(key: idempotencyKey, () {
    final record = _find(deliveryId);
    if (record.delivery.status == DeliveryStatus.assigned) {
      record.update(status: DeliveryStatus.rejected);
    }
  });

  @override
  Future<Delivery?> fetchActive() => _call(() => _active?.delivery);

  @override
  Future<Delivery> fetchDelivery(String deliveryId) =>
      _call(() => _find(deliveryId).delivery);

  @override
  Future<Delivery> reportArrival(
    String deliveryId,
    ArrivalReport report, {
    required String idempotencyKey,
  }) => _call(key: idempotencyKey, () {
    final record = _find(deliveryId);
    final action = report.stop == StopKind.pickup
        ? DeliveryAction.arriveAtPickup
        : DeliveryAction.arriveAtDropoff;
    final next = _transition(record, action);

    final stop = report.stop == StopKind.pickup
        ? record.delivery.pickup
        : record.delivery.dropoff;
    final fix = report.fix;
    if (fix != null && stop.location != null) {
      final distance = stop.location!.distanceTo(
        GeoPoint(fix.latitude, fix.longitude),
      );
      var allowance =
          (stop.geofenceRadiusMeters ?? 75) * 2 + (fix.accuracy ?? 0);
      if (report.detection == ArrivalDetection.manual) {
        allowance = max(allowance, 500);
      }
      if (distance > allowance) {
        throw DeliveryException(
          DeliveryErrorCode.tooFarFromStop,
          message: 'Reported location is ${distance.round()} m from the stop',
          statusCode: 422,
        );
      }
    }
    record.update(status: next);
    return record.delivery;
  });

  @override
  Future<Delivery> confirmPickup(
    String deliveryId, {
    required String idempotencyKey,
  }) => _call(key: idempotencyKey, () {
    final record = _find(deliveryId);
    final next = _transition(record, DeliveryAction.confirmPickup);
    record.update(status: next, pickedUpAt: _now());
    return record.delivery;
  });

  @override
  Future<Delivery> complete(
    String deliveryId,
    DeliveryProof proof, {
    LocationFix? fix,
    required String idempotencyKey,
  }) => _call(key: idempotencyKey, () {
    final record = _find(deliveryId);
    final next = _transition(record, DeliveryAction.complete);
    if (proof is! OtpProof) {
      throw const DeliveryException(
        DeliveryErrorCode.validation,
        message: 'Only OTP verification is supported',
        statusCode: 422,
      );
    }
    if (record.otpAttemptsLeft <= 0) {
      throw const DeliveryException(
        DeliveryErrorCode.otpLocked,
        message: 'Too many incorrect codes',
        statusCode: 423,
      );
    }
    if (proof.code != record.otp) {
      record.otpAttemptsLeft--;
      if (record.otpAttemptsLeft == 0) {
        throw const DeliveryException(
          DeliveryErrorCode.otpLocked,
          message: 'Too many incorrect codes',
          statusCode: 423,
        );
      }
      throw DeliveryException(
        DeliveryErrorCode.invalidOtp,
        message: 'Incorrect code',
        statusCode: 422,
        attemptsRemaining: record.otpAttemptsLeft,
      );
    }
    record.update(status: next, completedAt: _now());
    return record.delivery;
  });

  @override
  Future<HistoryPage> fetchHistory({String? cursor, int limit = 20}) =>
      _call(() {
        final finished =
            _records.values
                .where(
                  (r) =>
                      r.delivery.status == DeliveryStatus.completed ||
                      (r.delivery.status == DeliveryStatus.cancelled &&
                          r.delivery.acceptedAt != null),
                )
                .toList()
              ..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
        final start = int.tryParse(cursor ?? '') ?? 0;
        final end = min(start + limit, finished.length);
        return HistoryPage(
          items: [
            for (final r in finished.sublist(min(start, end), end))
              _historyView(r.delivery),
          ],
          nextCursor: end < finished.length ? '$end' : null,
        );
      });

  @override
  Future<PartnerSummary> fetchSummary() => _call(() {
    final now = _now();
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(const Duration(days: 6));
    var todayCount = 0;
    var weekCount = 0;
    for (final r in _records.values) {
      final at = r.delivery.completedAt;
      if (r.delivery.status != DeliveryStatus.completed || at == null) continue;
      final local = at.toLocal();
      if (!local.isBefore(today)) todayCount++;
      if (!local.isBefore(weekStart)) weekCount++;
    }
    return PartnerSummary(
      completedToday: todayCount,
      completedThisWeek: weekCount,
    );
  });

  // --- internals -----------------------------------------------------------

  Iterable<_Record> get _pendingOffers => _records.values.where(
    (r) => r.delivery.status == DeliveryStatus.assigned,
  );

  _Record? get _active {
    for (final r in _records.values) {
      if (r.delivery.status.isActive) return r;
    }
    return null;
  }

  Future<T> _call<T>(T Function() body, {String? key}) async {
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency * (0.6 + _random.nextDouble() * 0.8));
    }
    final forced = _failNext;
    _failNext = null;
    final fail =
        forced != null ||
        (failureRate > 0 && _random.nextDouble() < failureRate);
    final responseLost = fail && key != null && (forced ?? _random.nextBool());
    if (fail && !responseLost) throw _networkError;

    final T result;
    if (key != null && _replies.containsKey(key)) {
      final reply = _replies[key];
      if (reply is DeliveryException) throw reply;
      result = (reply as _Reply).value as T;
    } else if (key != null) {
      try {
        result = body();
      } on DeliveryException catch (e) {
        _replies[key] = e;
        rethrow;
      }
      _replies[key] = _Reply(result);
    } else {
      result = body();
    }

    if (responseLost) throw _networkError;
    return result;
  }

  static const _networkError = DeliveryException(
    DeliveryErrorCode.network,
    message: 'Simulated network failure',
    retryable: true,
  );

  _Record _find(String id) =>
      _records[id] ??
      (throw const DeliveryException(
        DeliveryErrorCode.notFound,
        statusCode: 404,
      ));

  DeliveryStatus _transition(_Record record, DeliveryAction action) =>
      DeliveryTransitions.resultOf(record.delivery.status, action) ??
      (throw DeliveryException(
        DeliveryErrorCode.invalidTransition,
        message:
            'Cannot ${action.name} a delivery that is '
            '${record.delivery.status.wire}',
        statusCode: 409,
      ));

  void _expireStale() {
    final now = _now();
    for (final r in _pendingOffers.toList()) {
      if (r.expiresAt != null && !now.isBefore(r.expiresAt!)) {
        r.update(status: DeliveryStatus.expired);
      }
    }
  }

  DeliveryOffer _offerView(_Record r) {
    final d = r.delivery;
    final remaining = r.expiresAt!.difference(_now());
    final center = _center;
    return DeliveryOffer(
      id: d.id,
      reference: d.reference,
      pickup: d.pickup,
      dropoffArea: d.dropoff.area ?? '',
      expiresIn: remaining.isNegative ? Duration.zero : remaining,
      distanceToPickupMeters: center == null || d.pickup.location == null
          ? null
          : center.distanceTo(d.pickup.location!),
      tripDistanceMeters: d.tripDistanceMeters,
      estimatedMinutes: d.estimatedMinutes,
      payout: d.payout,
      parcel: d.parcel,
    );
  }

  /// History keeps only what the partner needs later: no exact drop-off
  /// address or coordinates.
  Delivery _historyView(Delivery d) => Delivery(
    id: d.id,
    reference: d.reference,
    status: d.status,
    pickup: DeliveryStop(
      kind: StopKind.pickup,
      name: d.pickup.name,
      area: d.pickup.area,
    ),
    dropoff: DeliveryStop(
      kind: StopKind.dropoff,
      name: d.dropoff.name,
      area: d.dropoff.area,
    ),
    parcel: d.parcel,
    tripDistanceMeters: d.tripDistanceMeters,
    payout: d.payout,
    acceptedAt: d.acceptedAt,
    pickedUpAt: d.pickedUpAt,
    completedAt: d.completedAt,
    cancelReason: d.cancelReason,
  );

  _Record _createOffer(GeoPoint near) {
    final pickupPlace = _pickups[_random.nextInt(_pickups.length)];
    final dropPlace = _dropoffs[_random.nextInt(_dropoffs.length)];
    final pickupAt = _randomPoint(near, 300, 1500);
    final dropoffAt = _randomPoint(pickupAt, 1500, 5000);
    final trip = pickupAt.distanceTo(dropoffAt) * 1.3;
    final id = 'dlv_${_sequence++}_${_random.nextInt(1 << 20)}';
    final record = _Record(
      Delivery(
        id: id,
        reference: 'ORD-$_sequence',
        status: DeliveryStatus.assigned,
        pickup: DeliveryStop(
          kind: StopKind.pickup,
          name: pickupPlace.$1,
          area: pickupPlace.$2,
          address: pickupPlace.$3,
          location: pickupAt,
          instructions: pickupPlace.$4,
        ),
        dropoff: DeliveryStop(
          kind: StopKind.dropoff,
          name: dropPlace.$1,
          area: dropPlace.$2,
          address: dropPlace.$3,
          location: dropoffAt,
          instructions: dropPlace.$4,
        ),
        parcel: _parcels[_random.nextInt(_parcels.length)],
        tripDistanceMeters: trip,
        estimatedMinutes: (trip / 1000 * 3).round() + 5,
        payout: Money(40 + (trip / 1000 * 12).round(), 'INR'),
      ),
      otp: '${1000 + _random.nextInt(9000)}',
      otpAttemptsLeft: maxOtpAttempts,
      expiresAt: _now().add(offerLifetime),
    );
    _records[id] = record;
    return record;
  }

  GeoPoint _randomPoint(GeoPoint from, double minMeters, double maxMeters) {
    final distance = minMeters + _random.nextDouble() * (maxMeters - minMeters);
    final angle = _random.nextDouble() * 2 * pi;
    return from.offset(
      north: distance * cos(angle),
      east: distance * sin(angle),
    );
  }

  void _seedHistory() {
    final now = _now();
    for (var i = 0; i < 23; i++) {
      final finished = now.subtract(Duration(hours: 3 + i * 9, minutes: i * 7));
      final pickup = _pickups[i % _pickups.length];
      final drop = _dropoffs[(i * 3) % _dropoffs.length];
      final cancelled = i % 7 == 4;
      final trip = 1800.0 + (i * 733) % 4200;
      final id = 'dlv_hist_$i';
      _records[id] = _Record(
        Delivery(
          id: id,
          reference: 'ORD-${48199 - i}',
          status: cancelled
              ? DeliveryStatus.cancelled
              : DeliveryStatus.completed,
          pickup: DeliveryStop(
            kind: StopKind.pickup,
            name: pickup.$1,
            area: pickup.$2,
          ),
          dropoff: DeliveryStop(
            kind: StopKind.dropoff,
            name: drop.$1,
            area: drop.$2,
          ),
          parcel: _parcels[i % _parcels.length],
          tripDistanceMeters: trip,
          payout: Money(40 + (trip / 1000 * 12).round(), 'INR'),
          acceptedAt: finished.subtract(const Duration(minutes: 34)),
          pickedUpAt: cancelled
              ? null
              : finished.subtract(const Duration(minutes: 21)),
          completedAt: cancelled ? null : finished,
          cancelReason: cancelled ? 'Recipient cancelled the order' : null,
        ),
        otp: '0000',
        otpAttemptsLeft: 0,
        finishedAt: finished,
      );
    }
  }

  static const _pickups = [
    (
      'Green Leaf Pharmacy',
      'Market Road',
      'Shop 4, Market Road',
      'Ask for the order at the billing counter.',
    ),
    ('Shree Stationers', 'Station Road', '12 Station Road', null),
    (
      'Daily Basket Grocery',
      'Sector 4',
      'Plot 21, Sector 4 Main Street',
      'Parcel is kept behind the counter.',
    ),
    (
      'Parcel Hub 4',
      'Industrial Area',
      'Unit 9, Industrial Area Phase II',
      'Show the order reference at gate 2.',
    ),
    (
      'Corner Bakehouse',
      'Old Town',
      '3 Clock Tower Lane',
      'Fragile. Keep the box upright.',
    ),
    ('City Mobile Repairs', 'Lake View', 'Shop 17, Lake View Arcade', null),
  ];

  static const _dropoffs = [
    (
      'Asha',
      'Riverside',
      'Flat 302, Tower B, Riverside Residency',
      'Security desk will call up. Wait at the lobby.',
    ),
    ('Rohan', 'Hill View Colony', 'House 14, Lane 3, Hill View Colony', null),
    (
      'Meera',
      'Market Road',
      'Shop 7, ground floor, Market Road',
      'Hand over to the shop owner only.',
    ),
    (
      'Kabir',
      'Business Park',
      'Office 1204, Orbit Business Park',
      'Visitors must sign in at reception.',
    ),
    ('Sana', 'Green Avenue', '22 Green Avenue, near the post office', null),
    (
      'Vikram',
      'Sector 9',
      'C-118, Sector 9',
      'Ring the bell twice. Dog in the house.',
    ),
  ];

  static const _parcels = [
    ParcelInfo(description: 'Small box', itemCount: 1, weightKg: 0.6),
    ParcelInfo(description: 'Document envelope', itemCount: 1, weightKg: 0.2),
    ParcelInfo(description: 'Medium box', itemCount: 2, weightKg: 2.4),
    ParcelInfo(description: 'Food parcel, keep upright', itemCount: 3),
  ];
}

class _Reply {
  const _Reply(this.value);
  final Object? value;
}

class _Record {
  _Record(
    this.delivery, {
    required this.otp,
    required this.otpAttemptsLeft,
    this.expiresAt,
    this._finishedAt,
  });

  Delivery delivery;
  final String otp;
  int otpAttemptsLeft;
  final DateTime? expiresAt;
  DateTime? _finishedAt;

  DateTime get finishedAt =>
      _finishedAt ?? delivery.completedAt ?? delivery.acceptedAt ?? DateTime(0);

  void update({
    required DeliveryStatus status,
    DateTime? acceptedAt,
    DateTime? pickedUpAt,
    DateTime? completedAt,
    String? cancelReason,
  }) {
    final d = delivery;
    delivery = Delivery(
      id: d.id,
      reference: d.reference,
      status: status,
      pickup: d.pickup,
      dropoff: d.dropoff,
      parcel: d.parcel,
      tripDistanceMeters: d.tripDistanceMeters,
      estimatedMinutes: d.estimatedMinutes,
      payout: d.payout,
      verification: d.verification,
      acceptedAt: acceptedAt ?? d.acceptedAt,
      pickedUpAt: pickedUpAt ?? d.pickedUpAt,
      completedAt: completedAt ?? d.completedAt,
      cancelReason: cancelReason ?? d.cancelReason,
    );
    if (status.isTerminal) _finishedAt ??= completedAt ?? DateTime.now();
  }
}
