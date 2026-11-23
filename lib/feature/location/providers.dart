import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import 'data/location_api.dart';
import 'data/location_record.dart';
import 'data/location_store.dart';
import 'services/connectivity_service.dart';
import 'services/location_source.dart';
import 'services/sync_coordinator.dart';
import 'services/sync_service.dart';
import 'tracking_controller.dart';

/// Overridden in `main()` with the opened SQLite store (and in tests).
final locationStoreProvider = Provider<LocationStore>(
  (ref) => throw UnimplementedError('locationStoreProvider must be overridden'),
);

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      contentType: Headers.jsonContentType,
    ),
  );
  ref.onDispose(dio.close);
  return dio;
});

final locationApiProvider = Provider<LocationApi>(
  (ref) => DioLocationApi(ref.watch(dioProvider)),
);

final connectivityServiceProvider = Provider<ConnectivityService>(
  (ref) => ConnectivityService(),
);

/// Live online/offline flag for the UI.
final isOnlineProvider = StreamProvider<bool>((ref) async* {
  final connectivity = ref.watch(connectivityServiceProvider);
  yield await connectivity.isOnline();
  yield* connectivity.onChanged;
});

final syncServiceProvider = Provider<SyncService>((ref) {
  final connectivity = ref.watch(connectivityServiceProvider);
  final service = SyncService(
    store: ref.watch(locationStoreProvider),
    api: ref.watch(locationApiProvider),
    isOnline: connectivity.isOnline,
  );
  ref.onDispose(service.dispose);
  return service;
});

final syncStateProvider = StreamProvider<SyncState>((ref) async* {
  final service = ref.watch(syncServiceProvider);
  yield service.state;
  yield* service.states;
});

/// Watching this starts automatic synchronisation for as long as it is alive.
final syncCoordinatorProvider = Provider<SyncCoordinator>((ref) {
  final coordinator = SyncCoordinator(
    service: ref.watch(syncServiceProvider),
    store: ref.watch(locationStoreProvider),
    connectivity: ref.watch(connectivityServiceProvider),
  )..start();
  ref.onDispose(coordinator.stop);
  return coordinator;
});

final locationSnapshotProvider = StreamProvider<LocationSnapshot>(
  (ref) => ref.watch(locationStoreProvider).watch(),
);

/// Builds the GPS or simulated source. Override in tests.
final locationSourceFactoryProvider =
    Provider<LocationSource Function({required bool simulated})>(
      (ref) =>
          ({required bool simulated}) => simulated
          ? SimulatedLocationSource()
          : GeolocatorLocationSource(),
    );

final trackingControllerProvider =
    NotifierProvider<TrackingController, TrackingState>(TrackingController.new);
