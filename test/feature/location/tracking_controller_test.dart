import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/location/data/location_record.dart';
import 'package:geoloc/feature/location/data/sqlite_location_store.dart';
import 'package:geoloc/feature/location/providers.dart';
import 'package:geoloc/feature/location/services/connectivity_service.dart';
import 'package:geoloc/feature/location/services/location_source.dart';
import 'package:geoloc/feature/location/services/sync_coordinator.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockConnectivityService extends Mock implements ConnectivityService {}

class MockSyncCoordinator extends Mock implements SyncCoordinator {}

class FakeLocationSource implements LocationSource {
  final fixes = StreamController<LocationFix>();

  @override
  Stream<LocationFix> positions() => fixes.stream;
}

void main() {
  sqfliteFfiInit();

  late SqliteLocationStore store;
  late MockConnectivityService connectivity;
  late MockSyncCoordinator coordinator;
  late FakeLocationSource source;
  late ProviderContainer container;

  setUp(() async {
    store = await SqliteLocationStore.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    connectivity = MockConnectivityService();
    coordinator = MockSyncCoordinator();
    when(() => coordinator.requestSync()).thenReturn(null);
    source = FakeLocationSource();
    container = ProviderContainer(
      overrides: [
        locationStoreProvider.overrideWithValue(store),
        connectivityServiceProvider.overrideWithValue(connectivity),
        syncCoordinatorProvider.overrideWithValue(coordinator),
        locationSourceFactoryProvider.overrideWithValue(
          ({required bool simulated}) => source,
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await store.close();
  });

  /// Starts recording, feeds one fix and returns the record that was saved.
  Future<LocationRecord> recordOneFix() async {
    await container.read(trackingControllerProvider.notifier).start();
    source.fixes.add(
      LocationFix(latitude: 1, longitude: 2, timestamp: DateTime.utc(2026)),
    );
    final snapshot = await store.watch().firstWhere((s) => s.recent.isNotEmpty);
    return snapshot.recent.single;
  }

  test('a point saved without network is marked as recorded offline', () async {
    when(() => connectivity.isOnline()).thenAnswer((_) async => false);

    final saved = await recordOneFix();

    expect(saved.recordedOffline, isTrue);
    expect(saved.status, SyncStatus.pending);
    verify(() => coordinator.requestSync()).called(1);
  });

  test('a point saved with network is not marked', () async {
    when(() => connectivity.isOnline()).thenAnswer((_) async => true);

    expect((await recordOneFix()).recordedOffline, isFalse);
  });

  test('a failing network check still saves the point', () async {
    when(() => connectivity.isOnline()).thenThrow(Exception('plugin error'));

    expect((await recordOneFix()).recordedOffline, isFalse);
  });
}
