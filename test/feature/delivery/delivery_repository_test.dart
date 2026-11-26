import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/delivery/data/delivery_api.dart';
import 'package:geoloc/feature/delivery/data/delivery_repository.dart';
import 'package:geoloc/feature/delivery/data/mock/mock_delivery_api.dart';
import 'package:geoloc/feature/delivery/domain/delivery_status.dart';

import 'support.dart';

void main() {
  late DateTime now;
  late MockDeliveryApi mock;
  late SpyApi spy;
  late DeliveryRepository repo;
  late List<Duration> slept;
  var keys = 0;

  setUp(() {
    now = DateTime.utc(2026, 11, 26, 9);
    mock = quietMock(now: () => now);
    spy = SpyApi(mock);
    slept = [];
    repo = DeliveryRepository(
      spy,
      newKey: () => 'key-${keys++}',
      sleep: (d) async => slept.add(d),
    );
  });

  Future<String> offerId() async {
    await repo.setAvailability(true);
    return (await repo.offers()).offers.single.id;
  }

  test('transient failures are retried with the same key', () async {
    final id = await offerId();
    mock.debugFailNextCall();

    final delivery = await repo.accept(id);

    expect(delivery.status, DeliveryStatus.accepted);
    expect(spy.keys['accept'], hasLength(2));
    expect(spy.keys['accept']!.toSet(), hasLength(1));
    expect(slept, [const Duration(seconds: 1)]);
  });

  test('a lost response is not applied twice', () async {
    final id = await offerId();
    mock.debugFailNextCall(responseLost: true);

    final delivery = await repo.accept(id);

    // Without the shared key the retry would be a second acceptance and fail.
    expect(delivery.status, DeliveryStatus.accepted);
    expect(spy.count('accept'), 2);
  });

  test('the key survives a failure the partner retries by hand', () async {
    final retrying = DeliveryRepository(
      spy,
      newKey: () => 'key-${keys++}',
      retryDelays: const [],
    );
    final id = await offerId();

    mock.debugFailNextCall(responseLost: true);
    await expectLater(retrying.accept(id), throwsA(isA<DeliveryException>()));
    final second = await retrying.accept(id);

    expect(second.status, DeliveryStatus.accepted);
    expect(spy.keys['accept']![0], spy.keys['accept']![1]);
  });

  test('a definitive failure is not retried and releases the key', () async {
    final id = await offerId();
    now = now.add(const Duration(minutes: 5)); // offer expired

    await expectLater(
      repo.accept(id),
      throwsA(
        isA<DeliveryException>().having(
          (e) => e.code,
          'code',
          DeliveryErrorCode.offerUnavailable,
        ),
      ),
    );
    expect(spy.count('accept'), 1);
    expect(slept, isEmpty);
  });

  test(
    'a different code is a new attempt; the same code reuses the key',
    () async {
      final id = await offerId();
      await repo.accept(id);
      await repo.reportArrival(
        id,
        StopKind.pickup,
        detection: ArrivalDetection.manual,
      );
      await repo.confirmPickup(id);
      await repo.reportArrival(
        id,
        StopKind.dropoff,
        detection: ArrivalDetection.manual,
      );

      await expectLater(
        repo.completeWithOtp(id, '0001'),
        throwsA(isA<DeliveryException>()),
      );
      await expectLater(
        repo.completeWithOtp(id, '0002'),
        throwsA(isA<DeliveryException>()),
      );
      final done = await repo.completeWithOtp(id, mock.debugOtp(id)!);

      expect(done.status, DeliveryStatus.completed);
      expect(spy.keys['complete']!.toSet(), hasLength(3));
    },
  );

  test('retries stop after the configured attempts', () async {
    final id = await offerId();
    final failing = DeliveryRepository(
      _AlwaysOffline(spy),
      sleep: (d) async => slept.add(d),
    );

    await expectLater(
      failing.accept(id),
      throwsA(
        isA<DeliveryException>().having((e) => e.retryable, 'retryable', true),
      ),
    );
    expect(slept, [const Duration(seconds: 1), const Duration(seconds: 3)]);
  });
}

class _AlwaysOffline extends SpyApi {
  _AlwaysOffline(super.inner);

  @override
  Future<Never> accept(
    String deliveryId, {
    required String idempotencyKey,
  }) async =>
      throw const DeliveryException(DeliveryErrorCode.network, retryable: true);
}
