import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/delivery/application/offers_controller.dart';
import 'package:geoloc/feature/delivery/data/mock/mock_delivery_api.dart';
import 'package:geoloc/feature/delivery/delivery_providers.dart';
import 'package:geoloc/feature/delivery/domain/delivery_status.dart';
import 'package:riverpod/riverpod.dart';

import 'support.dart';

void main() {
  late MockDeliveryApi mock;
  late SpyApi spy;
  late FakeLocations locations;
  late ProviderContainer c;
  late DateTime Function() now;

  /// Builds the container inside [async] and goes online.
  void goOnline(FakeAsync async) {
    now = async.getClock(DateTime.utc(2026, 11, 26, 9)).now;
    mock = quietMock(now: now);
    spy = SpyApi(mock);
    locations = FakeLocations();
    c = makeContainer(api: spy, clock: now, locations: locations);
    c.listen(offersProvider, (_, _) {});
    async.flushMicrotasks();
    c.read(availabilityProvider.notifier).setOnline(true);
    async.flushMicrotasks();
  }

  T settle<T>(FakeAsync async, Future<T> future) {
    late T value;
    future.then((v) => value = v);
    async.flushMicrotasks();
    return value;
  }

  test('nothing is polled or tracked while offline', () {
    fakeAsync((async) {
      final clock = async.getClock(DateTime.utc(2026, 11, 26, 9)).now;
      final spy = SpyApi(quietMock(now: clock));
      final locations = FakeLocations();
      final c = makeContainer(api: spy, clock: clock, locations: locations);
      c.listen(offersProvider, (_, _) {});
      async.elapse(const Duration(minutes: 1));

      expect(spy.count('fetchOffers'), 0);
      expect(locations.dispatch.isListening, isFalse);
      expect(c.read(offersProvider).listening, isFalse);
    });
  });

  test(
    'polls while online with the coarse location profile, stops offline',
    () {
      fakeAsync((async) {
        goOnline(async);
        expect(locations.dispatch.isListening, isTrue);
        expect(locations.navigation.isListening, isFalse);
        expect(c.read(offersProvider).offers, hasLength(1));

        async.elapse(const Duration(seconds: 10));
        expect(spy.count('fetchOffers'), 3);

        c.read(availabilityProvider.notifier).setOnline(false);
        async.flushMicrotasks();
        expect(locations.dispatch.isListening, isFalse);
        expect(c.read(offersProvider).offers, isEmpty);
        final polls = spy.count('fetchOffers');
        async.elapse(const Duration(minutes: 1));
        expect(spy.count('fetchOffers'), polls);
      });
    },
  );

  test('re-polling does not extend the response window', () {
    fakeAsync((async) {
      goOnline(async);
      final deadline = c.read(offersProvider).offers.single.deadline;
      async.elapse(const Duration(seconds: 15));
      expect(c.read(offersProvider).offers.single.deadline, deadline);
    });
  });

  test('an offer that ran out is shown as expired, refused, then removed', () {
    fakeAsync((async) {
      goOnline(async);
      final id = c.read(offersProvider).offers.single.offer.id;

      async.elapse(const Duration(seconds: 30));
      final view = c.read(offersProvider).offers.single;
      expect(view.isExpired(now()), isTrue);

      final accepted = settle(
        async,
        c.read(offersProvider.notifier).accept(id),
      );
      expect(accepted, isFalse);
      expect(c.read(offersProvider).notice, OffersNotice.expired);
      expect(spy.count('accept'), 0);

      async.elapse(const Duration(seconds: 5));
      expect(c.read(offersProvider).offers, isEmpty);
    });
  });

  test('a double tap accepts once and hands over to the active delivery', () {
    fakeAsync((async) {
      goOnline(async);
      final notifier = c.read(offersProvider.notifier);
      final id = c.read(offersProvider).offers.single.offer.id;

      spy.gate = Completer<void>();
      bool? first;
      bool? second;
      notifier.accept(id).then((v) => first = v);
      notifier.accept(id).then((v) => second = v);
      async.flushMicrotasks();
      expect(c.read(offersProvider).acceptingId, id);
      expect(second, isFalse);

      spy.gate!.complete();
      spy.gate = null;
      async.flushMicrotasks();

      expect(first, isTrue);
      expect(spy.count('accept'), 1);
      expect(
        c.read(activeDeliveryProvider).delivery?.status,
        DeliveryStatus.accepted,
      );
      // Busy now: no more offers, and GPS switches to the navigation profile.
      expect(c.read(offersProvider).offers, isEmpty);
      expect(locations.dispatch.isListening, isFalse);
      expect(locations.navigation.isListening, isTrue);
      final polls = spy.count('fetchOffers');
      async.elapse(const Duration(seconds: 30));
      expect(spy.count('fetchOffers'), polls);
    });
  });

  test('an offer withdrawn by dispatch is removed with a notice', () {
    fakeAsync((async) {
      goOnline(async);
      final id = c.read(offersProvider).offers.single.offer.id;
      mock.debugCancel(id);

      final accepted = settle(
        async,
        c.read(offersProvider.notifier).accept(id),
      );

      expect(accepted, isFalse);
      expect(c.read(offersProvider).notice, OffersNotice.unavailable);
      expect(c.read(offersProvider).offers, isEmpty);
      expect(c.read(activeDeliveryProvider).delivery, isNull);
    });
  });

  test('reject removes the offer and tells the backend', () {
    fakeAsync((async) {
      goOnline(async);
      final id = c.read(offersProvider).offers.single.offer.id;

      c.read(offersProvider.notifier).reject(id);
      async.flushMicrotasks();

      expect(c.read(offersProvider).offers, isEmpty);
      expect(spy.count('reject'), 1);
    });
  });
}
