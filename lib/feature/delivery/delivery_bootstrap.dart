import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../core/config.dart';
import '../location/providers.dart';
import '../location/services/location_source.dart';
import 'data/breadcrumb_sink.dart';
import 'data/http_delivery_api.dart';
import 'data/mock/mock_delivery_api.dart';
import 'data/route_service.dart';
import 'delivery_config.dart';
import 'delivery_providers.dart';
import 'services/navigation_launcher.dart';

/// Platform implementations for the delivery feature, passed to the root
/// `ProviderScope`. Tests use their own overrides instead.
List<Override> deliveryOverrides(DeliveryConfig config) {
  // Mock mode is chosen explicitly at build time; it is never a fallback
  // for a failing real backend.
  final mock = config.isMock
      ? MockDeliveryApi(failureRate: config.mockFailureRate)
      : null;

  return [
    deliveryConfigProvider.overrideWithValue(config),
    mockDeliveryApiProvider.overrideWithValue(mock),
    deliveryApiProvider.overrideWith(
      (ref) => mock ?? HttpDeliveryApi(ref.watch(deliveryDioProvider)),
    ),
    deliveryLocationSourceProvider.overrideWithValue(_gpsFor),
    breadcrumbSinkProvider.overrideWith(
      (ref) => StoreBreadcrumbSink(
        ref.watch(locationStoreProvider),
        onRecorded: () => ref.read(syncCoordinatorProvider).requestSync(),
      ),
    ),
    routeServiceProvider.overrideWith((ref) {
      if (config.routingUrl.isEmpty) return const StraightLineRouteService();
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      ref.onDispose(dio.close);
      return OsrmRouteService(dio, baseUrl: config.routingUrl);
    }),
  ];
}

/// HTTP client for the delivery API (`API_BASE_URL`).
final deliveryDioProvider = Provider<Dio>((ref) {
  final config = ref.watch(deliveryConfigProvider);
  final dio = Dio(
    BaseOptions(
      baseUrl: apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      contentType: Headers.jsonContentType,
      responseType: ResponseType.json,
    ),
  );
  // There is no sign-in flow yet. Until there is, a development token can be
  // passed with --dart-define (ignored in release builds); see
  // docs/delivery-api.md for what the session flow needs to provide.
  final devToken = config.devPartnerToken;
  dio.interceptors.add(
    AuthInterceptor(() async => devToken.isEmpty ? null : devToken),
  );
  ref.onDispose(dio.close);
  return dio;
});

final navigationLauncherProvider = Provider<NavigationLauncher>(
  (ref) => const UrlNavigationLauncher(),
);

LocationSource _gpsFor(TrackingProfile profile) => switch (profile) {
  // Coarse and infrequent: enough for "1.2 km to pickup" and a heartbeat.
  TrackingProfile.dispatch => GeolocatorLocationSource(
    interval: const Duration(seconds: 30),
    highAccuracy: false,
    distanceFilterMeters: 50,
    notificationTitle: "You're online",
    notificationText: 'Geoloc uses your location to offer nearby deliveries.',
  ),
  // No distance filter: arrival detection needs fixes while standing still.
  TrackingProfile.navigation => GeolocatorLocationSource(
    interval: const Duration(seconds: 5),
    notificationTitle: 'Delivery in progress',
    notificationText:
        'Your location is shared with dispatch until the delivery is done.',
  ),
};
