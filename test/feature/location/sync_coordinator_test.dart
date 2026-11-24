import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/location/data/location_store.dart';
import 'package:geoloc/feature/location/services/connectivity_service.dart';
import 'package:geoloc/feature/location/services/sync_coordinator.dart';
import 'package:geoloc/feature/location/services/sync_service.dart';
import 'package:mocktail/mocktail.dart';

class MockSyncService extends Mock implements SyncService {}

class MockLocationStore extends Mock implements LocationStore {}

class MockConnectivityService extends Mock implements ConnectivityService {}

// testWidgets runs in a fake-time zone, so the coordinator's timers can be
// fast-forwarded with tester.pump(duration).
void main() {
  late MockSyncService service;
  late MockLocationStore store;
  late MockConnectivityService connectivity;
  late StreamController<bool> network;

  setUp(() {
    service = MockSyncService();
    store = MockLocationStore();
    connectivity = MockConnectivityService();
    network = StreamController<bool>.broadcast();
    when(() => connectivity.onChanged).thenAnswer((_) => network.stream);
    // A pending record whose backoff has already expired.
    when(() => store.earliestRetryAt())
        .thenAnswer((_) async => DateTime.utc(2000));
  });

  tearDown(() => network.close());

  SyncCoordinator startCoordinator() => SyncCoordinator(
    service: service,
    store: store,
    connectivity: connectivity,
  )..start();

  testWidgets('retries a due record about a second later while online', (
    tester,
  ) async {
    when(() => service.sync()).thenAnswer((_) async => SyncOutcome.failed);
    final coordinator = startCoordinator();

    await tester.pump(Duration.zero); // start-up sync
    verify(() => service.sync()).called(1);

    await tester.pump(const Duration(seconds: 1));
    verify(() => service.sync()).called(1);

    coordinator.stop();
  });

  testWidgets(
    'does not poll while offline and syncs when the network returns',
    (tester) async {
      when(() => service.sync()).thenAnswer((_) async => SyncOutcome.offline);
      final coordinator = startCoordinator();

      await tester.pump(Duration.zero); // start-up sync finds no network
      verify(() => service.sync()).called(1);

      // Shorter than the 1-minute safety timer: nothing should run.
      await tester.pump(const Duration(seconds: 30));
      verifyNever(() => service.sync());

      when(() => service.sync()).thenAnswer((_) async => SyncOutcome.completed);
      network.add(true);
      await tester.pump(Duration.zero);
      verify(() => service.sync()).called(1);

      coordinator.stop();
    },
  );
}
