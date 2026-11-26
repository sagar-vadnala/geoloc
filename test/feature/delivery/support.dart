import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/delivery/data/delivery_api.dart';
import 'package:geoloc/feature/delivery/data/delivery_repository.dart';
import 'package:geoloc/feature/delivery/data/mock/mock_delivery_api.dart';
import 'package:geoloc/feature/delivery/delivery_config.dart';
import 'package:geoloc/feature/delivery/delivery_providers.dart';
import 'package:geoloc/feature/delivery/domain/arrival_detector.dart';
import 'package:geoloc/feature/delivery/domain/delivery.dart';
import 'package:geoloc/feature/delivery/domain/geo.dart';
import 'package:geoloc/feature/location/domain/location_fix.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';

const testConfig = DeliveryConfig(
  arrival: ArrivalConfig(
    radiusMeters: 75,
    maxAccuracyMeters: 50,
    requiredFixes: 3,
    minDwell: Duration(seconds: 5),
  ),
);

/// A location source the test drives by hand.
class FakeLocationSource implements LocationSource {
  final _controller = StreamController<LocationFix>.broadcast();
  int subscriptions = 0;

  bool get isListening => _controller.hasListener;

  @override
  Stream<LocationFix> positions() {
    subscriptions++;
    return _controller.stream;
  }

  void emit(GeoPoint at, DateTime time, {double accuracy = 8}) =>
      _controller.add(
        LocationFix(
          latitude: at.latitude,
          longitude: at.longitude,
          accuracy: accuracy,
          timestamp: time,
        ),
      );

  void fail(Object error) => _controller.addError(error);
}

class FakeLocations {
  final dispatch = FakeLocationSource();
  final navigation = FakeLocationSource();

  LocationSource call(TrackingProfile profile) => switch (profile) {
    TrackingProfile.dispatch => dispatch,
    TrackingProfile.navigation => navigation,
  };
}

/// Mock backend with no latency, no seeded history and a fixed seed.
MockDeliveryApi quietMock({
  required DateTime Function() now,
  bool seedHistory = false,
  Duration offerLifetime = const Duration(seconds: 30),
}) => MockDeliveryApi(
  random: Random(7),
  now: now,
  latency: Duration.zero,
  seedHistory: seedHistory,
  firstOfferDelay: Duration.zero,
  offerGap: const Duration(hours: 1),
  offerLifetime: offerLifetime,
);

ProviderContainer makeContainer({
  required DeliveryApi api,
  required DateTime Function() clock,
  FakeLocations? locations,
  DeliveryConfig config = testConfig,
  List<Override> overrides = const [],
}) {
  final fakes = locations ?? FakeLocations();
  final container = ProviderContainer(
    overrides: [
      deliveryConfigProvider.overrideWithValue(config),
      deliveryApiProvider.overrideWithValue(api),
      deliveryRepositoryProvider.overrideWith(
        (ref) => DeliveryRepository(
          ref.watch(deliveryApiProvider),
          sleep: (_) async {},
        ),
      ),
      deliveryLocationSourceProvider.overrideWithValue(fakes.call),
      clockProvider.overrideWithValue(clock),
      ...overrides,
    ],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  return container;
}

/// Wraps an API to count calls and optionally hold requests open.
class SpyApi implements DeliveryApi {
  SpyApi(this.inner);

  final DeliveryApi inner;
  final calls = <String, int>{};
  final keys = <String, List<String>>{};

  /// When set, mutating calls wait for it before reaching [inner].
  Completer<void>? gate;

  int count(String name) => calls[name] ?? 0;

  Future<T> _track<T>(
    String name,
    Future<T> Function() call, [
    String? key,
  ]) async {
    calls[name] = count(name) + 1;
    if (key != null) (keys[name] ??= []).add(key);
    final g = gate;
    if (g != null && key != null) await g.future;
    return call();
  }

  @override
  Future<void> setAvailability({
    required bool online,
    GeoPoint? at,
    required String idempotencyKey,
  }) => _track(
    'setAvailability',
    () => inner.setAvailability(
      online: online,
      at: at,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<OffersResult> fetchOffers({GeoPoint? at}) =>
      _track('fetchOffers', () => inner.fetchOffers(at: at));

  @override
  Future<Delivery> accept(
    String deliveryId, {
    required String idempotencyKey,
  }) => _track(
    'accept',
    () => inner.accept(deliveryId, idempotencyKey: idempotencyKey),
    idempotencyKey,
  );

  @override
  Future<void> reject(
    String deliveryId, {
    String? reason,
    required String idempotencyKey,
  }) => _track(
    'reject',
    () => inner.reject(
      deliveryId,
      reason: reason,
      idempotencyKey: idempotencyKey,
    ),
    idempotencyKey,
  );

  @override
  Future<Delivery?> fetchActive() => _track('fetchActive', inner.fetchActive);

  @override
  Future<Delivery> fetchDelivery(String deliveryId) =>
      _track('fetchDelivery', () => inner.fetchDelivery(deliveryId));

  @override
  Future<Delivery> reportArrival(
    String deliveryId,
    ArrivalReport report, {
    required String idempotencyKey,
  }) => _track(
    'reportArrival',
    () =>
        inner.reportArrival(deliveryId, report, idempotencyKey: idempotencyKey),
    idempotencyKey,
  );

  @override
  Future<Delivery> confirmPickup(
    String deliveryId, {
    required String idempotencyKey,
  }) => _track(
    'confirmPickup',
    () => inner.confirmPickup(deliveryId, idempotencyKey: idempotencyKey),
    idempotencyKey,
  );

  @override
  Future<Delivery> complete(
    String deliveryId,
    DeliveryProof proof, {
    LocationFix? fix,
    required String idempotencyKey,
  }) => _track(
    'complete',
    () => inner.complete(
      deliveryId,
      proof,
      fix: fix,
      idempotencyKey: idempotencyKey,
    ),
    idempotencyKey,
  );

  @override
  Future<HistoryPage> fetchHistory({String? cursor, int limit = 20}) => _track(
    'fetchHistory',
    () => inner.fetchHistory(cursor: cursor, limit: limit),
  );

  @override
  Future<PartnerSummary> fetchSummary() =>
      _track('fetchSummary', inner.fetchSummary);
}
