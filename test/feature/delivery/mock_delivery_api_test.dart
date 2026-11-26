import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/delivery/data/delivery_api.dart';
import 'package:geoloc/feature/delivery/data/mock/mock_delivery_api.dart';
import 'package:geoloc/feature/delivery/domain/delivery.dart';
import 'package:geoloc/feature/delivery/domain/delivery_status.dart';
import 'package:geoloc/feature/delivery/domain/geo.dart';
import 'package:geoloc/feature/location/domain/location_fix.dart';

import 'support.dart';

void main() {
  late DateTime now;
  late MockDeliveryApi api;
  var key = 0;
  String k() => 'key-${key++}';

  LocationFix fixAt(GeoPoint p, {double accuracy = 8}) => LocationFix(
    latitude: p.latitude,
    longitude: p.longitude,
    accuracy: accuracy,
    timestamp: now,
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 26, 9);
    api = quietMock(now: () => now);
  });

  Future<Delivery> acceptedDelivery() async {
    await api.setAvailability(online: true, idempotencyKey: k());
    final offers = await api.fetchOffers(at: const GeoPoint(19.07, 72.87));
    return api.accept(offers.offers.single.id, idempotencyKey: k());
  }

  test('offers only reveal the drop-off area', () async {
    await api.setAvailability(online: true, idempotencyKey: k());
    final offer = (await api.fetchOffers(at: const GeoPoint(19.07, 72.87)))
        .offers
        .single;

    expect(offer.dropoffArea, isNotEmpty);
    expect(offer.pickup.location, isNotNull);
    expect(offer.expiresIn, const Duration(seconds: 30));
    expect(offer.distanceToPickupMeters, inInclusiveRange(300, 1500));

    final delivery = await api.accept(offer.id, idempotencyKey: k());
    expect(delivery.dropoff.address, isNotNull);
    expect(delivery.dropoff.location, isNotNull);
  });

  test('no offers while offline', () async {
    expect((await api.fetchOffers()).offers, isEmpty);
  });

  test('an expired offer cannot be accepted', () async {
    await api.setAvailability(online: true, idempotencyKey: k());
    final offer = (await api.fetchOffers()).offers.single;
    now = now.add(const Duration(seconds: 31));

    await expectLater(
      api.accept(offer.id, idempotencyKey: k()),
      throwsA(
        isA<DeliveryException>().having(
          (e) => e.code,
          'code',
          DeliveryErrorCode.offerUnavailable,
        ),
      ),
    );
    expect(
      (await api.fetchOffers()).offers.where((o) => o.id == offer.id),
      isEmpty,
    );
  });

  test('the same idempotency key returns the first result', () async {
    await api.setAvailability(online: true, idempotencyKey: k());
    final offer = (await api.fetchOffers()).offers.single;

    final first = await api.accept(offer.id, idempotencyKey: 'same');
    final again = await api.accept(offer.id, idempotencyKey: 'same');
    expect(again.status, DeliveryStatus.accepted);
    expect(again.acceptedAt, first.acceptedAt);

    // A different key is a second acceptance, which is refused.
    await expectLater(
      api.accept(offer.id, idempotencyKey: 'other'),
      throwsA(isA<DeliveryException>()),
    );
  });

  test('a lost response can be retried safely with the same key', () async {
    final d = await acceptedDelivery();
    final stop = d.pickup.location!;
    await api.reportArrival(
      d.id,
      ArrivalReport(
        stop: StopKind.pickup,
        detection: ArrivalDetection.auto,
        fix: fixAt(stop),
      ),
      idempotencyKey: 'arrive',
    );

    api.debugFailNextCall(responseLost: true);
    await expectLater(
      api.confirmPickup(d.id, idempotencyKey: 'pickup'),
      throwsA(
        isA<DeliveryException>().having((e) => e.retryable, 'retryable', true),
      ),
    );
    // The change was applied even though the phone saw an error...
    expect((await api.fetchActive())!.status, DeliveryStatus.inTransit);
    // ...and the retry gets the stored result instead of a conflict.
    final retried = await api.confirmPickup(d.id, idempotencyKey: 'pickup');
    expect(retried.status, DeliveryStatus.inTransit);
  });

  test('out-of-order steps are rejected as invalid transitions', () async {
    final d = await acceptedDelivery();
    for (final call in [
      () => api.confirmPickup(d.id, idempotencyKey: k()),
      () => api.complete(d.id, const OtpProof('0000'), idempotencyKey: k()),
      () => api.reportArrival(
        d.id,
        const ArrivalReport(
          stop: StopKind.dropoff,
          detection: ArrivalDetection.manual,
        ),
        idempotencyKey: k(),
      ),
    ]) {
      await expectLater(
        call(),
        throwsA(
          isA<DeliveryException>().having(
            (e) => e.code,
            'code',
            DeliveryErrorCode.invalidTransition,
          ),
        ),
      );
    }
  });

  test('arrival far from the stop is refused by the backend check', () async {
    final d = await acceptedDelivery();
    final far = d.pickup.location!.offset(north: 2000);
    await expectLater(
      api.reportArrival(
        d.id,
        ArrivalReport(
          stop: StopKind.pickup,
          detection: ArrivalDetection.auto,
          fix: fixAt(far),
        ),
        idempotencyKey: k(),
      ),
      throwsA(
        isA<DeliveryException>().having(
          (e) => e.code,
          'code',
          DeliveryErrorCode.tooFarFromStop,
        ),
      ),
    );
  });

  group('delivery code', () {
    late Delivery atDropoff;

    setUp(() async {
      final d = await acceptedDelivery();
      await api.reportArrival(
        d.id,
        const ArrivalReport(
          stop: StopKind.pickup,
          detection: ArrivalDetection.manual,
        ),
        idempotencyKey: k(),
      );
      await api.confirmPickup(d.id, idempotencyKey: k());
      atDropoff = await api.reportArrival(
        d.id,
        const ArrivalReport(
          stop: StopKind.dropoff,
          detection: ArrivalDetection.manual,
        ),
        idempotencyKey: k(),
      );
    });

    test('a wrong code is refused with the attempts left', () async {
      await expectLater(
        api.complete(atDropoff.id, const OtpProof('0000'), idempotencyKey: k()),
        throwsA(
          isA<DeliveryException>()
              .having((e) => e.code, 'code', DeliveryErrorCode.invalidOtp)
              .having((e) => e.attemptsRemaining, 'attempts', 4),
        ),
      );
      expect((await api.fetchActive())!.status, DeliveryStatus.atDropoff);
    });

    test('the right code completes the delivery', () async {
      final code = api.debugOtp(atDropoff.id)!;
      final done = await api.complete(
        atDropoff.id,
        OtpProof(code),
        idempotencyKey: k(),
      );
      expect(done.status, DeliveryStatus.completed);
      expect(done.completedAt, now);
      expect(await api.fetchActive(), isNull);
    });

    test('too many wrong codes lock the delivery', () async {
      final right = api.debugOtp(atDropoff.id)!;
      final wrong = right == '1111' ? '2222' : '1111';
      for (var i = 0; i < 4; i++) {
        await expectLater(
          api.complete(atDropoff.id, OtpProof(wrong), idempotencyKey: k()),
          throwsA(isA<DeliveryException>()),
        );
      }
      await expectLater(
        api.complete(atDropoff.id, OtpProof(wrong), idempotencyKey: k()),
        throwsA(
          isA<DeliveryException>().having(
            (e) => e.code,
            'code',
            DeliveryErrorCode.otpLocked,
          ),
        ),
      );
      await expectLater(
        api.complete(atDropoff.id, OtpProof(right), idempotencyKey: k()),
        throwsA(
          isA<DeliveryException>().having(
            (e) => e.code,
            'code',
            DeliveryErrorCode.otpLocked,
          ),
        ),
      );
    });
  });

  test('history pages through finished deliveries without addresses', () async {
    final seeded = quietMock(now: () => now, seedHistory: true);
    final first = await seeded.fetchHistory(limit: 20);
    expect(first.items, hasLength(20));
    expect(first.nextCursor, isNotNull);
    final second = await seeded.fetchHistory(
      cursor: first.nextCursor,
      limit: 20,
    );
    expect(second.items, hasLength(3));
    expect(second.nextCursor, isNull);

    final all = [...first.items, ...second.items];
    expect(all.map((d) => d.id).toSet(), hasLength(23));
    expect(
      all.every((d) => d.dropoff.address == null && d.dropoff.location == null),
      isTrue,
    );
    expect(
      all.every(
        (d) =>
            d.status == DeliveryStatus.completed ||
            d.status == DeliveryStatus.cancelled,
      ),
      isTrue,
    );
  });
}
