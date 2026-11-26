import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/delivery/application/active_delivery_controller.dart';
import 'package:geoloc/feature/delivery/data/breadcrumb_sink.dart';
import 'package:geoloc/feature/delivery/data/delivery_api.dart';
import 'package:geoloc/feature/delivery/data/mock/mock_delivery_api.dart';
import 'package:geoloc/feature/delivery/delivery_providers.dart';
import 'package:geoloc/feature/delivery/domain/delivery.dart';
import 'package:geoloc/feature/delivery/domain/delivery_status.dart';
import 'package:geoloc/feature/delivery/domain/geo.dart';
import 'package:geoloc/feature/location/domain/location_fix.dart';
import 'package:riverpod/riverpod.dart';

import 'support.dart';

class RecordingSink implements BreadcrumbSink {
  final points = <(String, LocationFix)>[];

  @override
  Future<void> record(String deliveryId, LocationFix fix) async =>
      points.add((deliveryId, fix));
}

enum Stage { accepted, atPickup, inTransit, atDropoff }

void main() {
  late DateTime Function() now;
  late MockDeliveryApi mock;
  late SpyApi spy;
  late FakeLocations locations;
  late RecordingSink sink;
  late ProviderContainer c;
  late Delivery start;

  T settle<T>(FakeAsync async, Future<T> future) {
    late T value;
    future.then((v) => value = v);
    async.flushMicrotasks();
    return value;
  }

  /// Puts a delivery in [stage] on the mock backend, then starts the app.
  void setUpAt(
    FakeAsync async,
    Stage stage, {
    SpyApi Function(MockDeliveryApi mock)? wrap,
  }) {
    now = async.getClock(DateTime.utc(2026, 11, 26, 9)).now;
    mock = quietMock(now: now);
    var n = 0;
    String key() => 'setup-${n++}';
    settle(async, mock.setAvailability(online: true, idempotencyKey: key()));
    final offer = settle(async, mock.fetchOffers()).offers.single;
    var d = settle(async, mock.accept(offer.id, idempotencyKey: key()));
    if (stage.index >= Stage.atPickup.index) {
      d = settle(
        async,
        mock.reportArrival(
          d.id,
          const ArrivalReport(
            stop: StopKind.pickup,
            detection: ArrivalDetection.manual,
          ),
          idempotencyKey: key(),
        ),
      );
    }
    if (stage.index >= Stage.inTransit.index) {
      d = settle(async, mock.confirmPickup(d.id, idempotencyKey: key()));
    }
    if (stage.index >= Stage.atDropoff.index) {
      d = settle(
        async,
        mock.reportArrival(
          d.id,
          const ArrivalReport(
            stop: StopKind.dropoff,
            detection: ArrivalDetection.manual,
          ),
          idempotencyKey: key(),
        ),
      );
    }
    start = d;
    spy = wrap?.call(mock) ?? SpyApi(mock);
    locations = FakeLocations();
    sink = RecordingSink();
    c = makeContainer(
      api: spy,
      clock: now,
      locations: locations,
      overrides: [breadcrumbSinkProvider.overrideWithValue(sink)],
    );
    c.listen(activeDeliveryProvider, (_, _) {});
    async.flushMicrotasks();
  }

  ActiveDeliveryState state() => c.read(activeDeliveryProvider);
  ActiveDeliveryController controller() =>
      c.read(activeDeliveryProvider.notifier);

  test('resumes the delivery from the backend and starts GPS tracking', () {
    fakeAsync((async) {
      setUpAt(async, Stage.accepted);
      expect(state().delivery?.id, start.id);
      expect(state().loading, isFalse);
      expect(locations.navigation.isListening, isTrue);
      expect(locations.dispatch.isListening, isFalse);
    });
  });

  test('arrival needs several readings inside the geofence', () {
    fakeAsync((async) {
      setUpAt(async, Stage.accepted);
      final pickup = start.pickup.location!;

      locations.navigation.emit(pickup.offset(north: 20), now());
      async.flushMicrotasks();
      expect(
        spy.count('reportArrival'),
        0,
        reason: 'one reading is not enough',
      );

      for (var i = 0; i < 3; i++) {
        async.elapse(const Duration(seconds: 3));
        locations.navigation.emit(pickup.offset(north: 10), now());
        async.flushMicrotasks();
      }

      expect(spy.count('reportArrival'), 1);
      expect(state().delivery?.status, DeliveryStatus.atPickup);

      // At the stop no further arrival is reported.
      locations.navigation.emit(pickup, now());
      async.flushMicrotasks();
      expect(spy.count('reportArrival'), 1);
      expect(locations.navigation.isListening, isTrue);
    });
  });

  test('inaccurate readings at the stop do not trigger arrival', () {
    fakeAsync((async) {
      setUpAt(async, Stage.accepted);
      final pickup = start.pickup.location!;
      for (var i = 0; i < 6; i++) {
        locations.navigation.emit(pickup, now(), accuracy: 150);
        async.elapse(const Duration(seconds: 3));
      }
      expect(spy.count('reportArrival'), 0);
      expect(state().locationIssue, LocationIssue.weakSignal);
    });
  });

  test('a double tap sends one request', () {
    fakeAsync((async) {
      setUpAt(async, Stage.atPickup);
      spy.gate = Completer<void>();
      bool? first;
      bool? second;
      controller().confirmPickup().then((v) => first = v);
      controller().confirmPickup().then((v) => second = v);
      async.flushMicrotasks();
      expect(state().pendingAction, DeliveryAction.confirmPickup);

      spy.gate!.complete();
      spy.gate = null;
      async.flushMicrotasks();

      expect(first, isTrue);
      expect(second, isFalse);
      expect(spy.count('confirmPickup'), 1);
      expect(state().delivery?.status, DeliveryStatus.inTransit);
    });
  });

  test('an action that does not fit the current status is never sent', () {
    fakeAsync((async) {
      setUpAt(async, Stage.accepted);
      expect(settle(async, controller().completeWithOtp('1234')), isFalse);
      expect(settle(async, controller().confirmPickup()), isFalse);
      expect(spy.count('complete'), 0);
      expect(spy.count('confirmPickup'), 0);
    });
  });

  test('reaching the drop-off does not complete the delivery', () {
    fakeAsync((async) {
      setUpAt(async, Stage.inTransit);
      final dropoff = start.dropoff.location!;
      for (var i = 0; i < 5; i++) {
        locations.navigation.emit(dropoff, now());
        async.elapse(const Duration(seconds: 3));
      }
      expect(state().delivery?.status, DeliveryStatus.atDropoff);
      expect(spy.count('complete'), 0);
    });
  });

  test('a wrong code is reported; the right one completes and stops GPS', () {
    fakeAsync((async) {
      setUpAt(async, Stage.atDropoff);
      final right = mock.debugOtp(start.id)!;
      final wrong = right == '1111' ? '2222' : '1111';

      expect(settle(async, controller().completeWithOtp(wrong)), isFalse);
      expect(state().actionError?.code, DeliveryErrorCode.invalidOtp);
      expect(state().actionError?.attemptsRemaining, 4);
      expect(state().delivery?.status, DeliveryStatus.atDropoff);

      expect(settle(async, controller().completeWithOtp(right)), isTrue);
      expect(state().delivery?.status, DeliveryStatus.completed);
      expect(state().actionError, isNull);
      expect(locations.navigation.isListening, isFalse);

      controller().dismiss();
      expect(state().delivery, isNull);
    });
  });

  test('a failed request keeps the state and can be retried', () {
    fakeAsync((async) {
      // Three failures exhaust the repository's automatic retries.
      setUpAt(
        async,
        Stage.atPickup,
        wrap: (mock) => _FailingPickup(mock, failures: 3),
      );

      expect(settle(async, controller().confirmPickup()), isFalse);
      expect(state().actionError?.retryable, isTrue);
      expect(state().failedAction, DeliveryAction.confirmPickup);
      expect(state().delivery?.status, DeliveryStatus.atPickup);

      expect(settle(async, controller().confirmPickup()), isTrue);
      expect(state().delivery?.status, DeliveryStatus.inTransit);
      expect(state().actionError, isNull);
    });
  });

  test('a cancellation by dispatch is picked up and tracking stops', () {
    fakeAsync((async) {
      setUpAt(async, Stage.inTransit);
      mock.debugCancel(start.id, reason: 'Recipient cancelled');

      async.elapse(const Duration(seconds: 30));

      expect(state().delivery?.status, DeliveryStatus.cancelled);
      expect(state().delivery?.cancelReason, 'Recipient cancelled');
      expect(locations.navigation.isListening, isFalse);
    });
  });

  test('location turned off is reported and tracking resumes by itself', () {
    fakeAsync((async) {
      setUpAt(async, Stage.accepted);
      expect(locations.navigation.subscriptions, 1);

      locations.navigation.fail(
        const LocationPermissionException('off', serviceDisabled: true),
      );
      async.flushMicrotasks();
      expect(state().locationIssue, LocationIssue.serviceDisabled);
      expect(locations.navigation.isListening, isFalse);

      async.elapse(const Duration(seconds: 10));
      expect(locations.navigation.subscriptions, 2);
      expect(locations.navigation.isListening, isTrue);
    });
  });

  test('no position for a while is reported', () {
    fakeAsync((async) {
      setUpAt(async, Stage.accepted);
      async.elapse(const Duration(seconds: 21));
      expect(state().locationIssue, LocationIssue.noFix);

      locations.navigation.emit(const GeoPoint(19, 72), now());
      async.flushMicrotasks();
      expect(state().locationIssue, isNull);
    });
  });

  test('breadcrumbs are throttled and tagged with the delivery', () {
    fakeAsync((async) {
      setUpAt(async, Stage.accepted);
      final here = start.pickup.location!.offset(north: 1500);
      for (var s = 0; s < 20; s++) {
        locations.navigation.emit(here, now());
        async.elapse(const Duration(seconds: 1));
      }
      expect(sink.points, hasLength(2), reason: 'one now, one after 15 s');
      expect(sink.points.every((p) => p.$1 == start.id), isTrue);
    });
  });

  test('simulated driving reaches the stop and is detected', () {
    fakeAsync((async) {
      setUpAt(async, Stage.accepted);
      controller().setSimulateMovement(true);
      expect(locations.navigation.isListening, isFalse);

      // 700 m north / 500 m east at 14 m/s, plus dwell.
      async.elapse(const Duration(minutes: 2));
      expect(state().delivery?.status, DeliveryStatus.atPickup);
    });
  });
}

class _FailingPickup extends SpyApi {
  _FailingPickup(super.inner, {required this.failures});

  int failures;

  @override
  Future<Delivery> confirmPickup(
    String deliveryId, {
    required String idempotencyKey,
  }) {
    if (failures-- > 0) {
      calls['confirmPickup'] = count('confirmPickup') + 1;
      return Future.error(
        const DeliveryException(DeliveryErrorCode.network, retryable: true),
      );
    }
    return super.confirmPickup(deliveryId, idempotencyKey: idempotencyKey);
  }
}
