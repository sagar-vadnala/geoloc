import 'domain/arrival_detector.dart';

enum DeliveryApiMode {
  /// In-app simulated backend. For development and demos only.
  mock,

  /// Real backend over HTTP at `API_BASE_URL`.
  http,
}

/// Service settings for the delivery feature, read from `--dart-define`
/// values so nothing service-specific is hardcoded in the code.
///
/// | define | default | |
/// | --- | --- | --- |
/// | `DELIVERY_API_MODE` | `mock` | `mock` or `http` |
/// | `GEOFENCE_RADIUS_M` | `75` | arrival radius when the backend sends none |
/// | `ARRIVAL_MAX_ACCURACY_M` | `50` | fixes less accurate than this are ignored |
/// | `ARRIVAL_FIXES` | `3` | consecutive fixes inside the fence |
/// | `ARRIVAL_DWELL_S` | `5` | seconds inside the fence |
/// | `OFFER_POLL_S` | `5` | how often to poll for requests while online |
/// | `MAP_TILE_URL` | OpenStreetMap | raster tile URL template |
/// | `MAP_TILE_ATTRIBUTION` | `OpenStreetMap contributors` | |
/// | `ROUTING_URL` | empty | OSRM-compatible routing server; empty draws a straight line |
/// | `DEV_PARTNER_TOKEN` | empty | bearer token for a dev backend; ignored in release builds |
/// | `MOCK_FAILURE_RATE` | `0` | share of mock calls that fail, to exercise retries |
class DeliveryConfig {
  const DeliveryConfig({
    this.apiMode = DeliveryApiMode.mock,
    this.arrival = const ArrivalConfig(),
    this.offerPollInterval = const Duration(seconds: 5),
    this.activeRefreshInterval = const Duration(seconds: 30),
    this.mapTileUrl = defaultTileUrl,
    this.mapAttribution = 'OpenStreetMap contributors',
    this.routingUrl = '',
    this.devPartnerToken = '',
    this.mockFailureRate = 0,
  });

  static const defaultTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  factory DeliveryConfig.fromEnvironment() {
    const mode = String.fromEnvironment(
      'DELIVERY_API_MODE',
      defaultValue: 'mock',
    );
    const tileUrl = String.fromEnvironment('MAP_TILE_URL');
    const attribution = String.fromEnvironment('MAP_TILE_ATTRIBUTION');
    const isRelease = bool.fromEnvironment('dart.vm.product');
    return DeliveryConfig(
      apiMode: mode == 'http' ? DeliveryApiMode.http : DeliveryApiMode.mock,
      arrival: ArrivalConfig(
        radiusMeters: _double(
          const String.fromEnvironment('GEOFENCE_RADIUS_M'),
          75,
        ),
        maxAccuracyMeters: _double(
          const String.fromEnvironment('ARRIVAL_MAX_ACCURACY_M'),
          50,
        ),
        requiredFixes: const int.fromEnvironment(
          'ARRIVAL_FIXES',
          defaultValue: 3,
        ),
        minDwell: const Duration(
          seconds: int.fromEnvironment('ARRIVAL_DWELL_S', defaultValue: 5),
        ),
      ),
      offerPollInterval: const Duration(
        seconds: int.fromEnvironment('OFFER_POLL_S', defaultValue: 5),
      ),
      mapTileUrl: tileUrl.isEmpty ? defaultTileUrl : tileUrl,
      mapAttribution: attribution.isEmpty
          ? 'OpenStreetMap contributors'
          : attribution,
      routingUrl: const String.fromEnvironment('ROUTING_URL'),
      devPartnerToken: isRelease
          ? ''
          : const String.fromEnvironment('DEV_PARTNER_TOKEN'),
      mockFailureRate: _double(
        const String.fromEnvironment('MOCK_FAILURE_RATE'),
        0,
      ),
    );
  }

  final DeliveryApiMode apiMode;
  final ArrivalConfig arrival;
  final Duration offerPollInterval;

  /// How often the active delivery is re-read from the backend, to pick up
  /// changes made elsewhere (for example a cancellation by dispatch).
  final Duration activeRefreshInterval;
  final String mapTileUrl;
  final String mapAttribution;
  final String routingUrl;
  final String devPartnerToken;
  final double mockFailureRate;

  bool get isMock => apiMode == DeliveryApiMode.mock;

  static double _double(String raw, double fallback) =>
      double.tryParse(raw) ?? fallback;
}
