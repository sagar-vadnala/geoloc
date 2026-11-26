import 'package:riverpod/riverpod.dart';

import '../location/domain/location_fix.dart';
import 'application/active_delivery_controller.dart';
import 'application/availability_controller.dart';
import 'application/history_controller.dart';
import 'application/offers_controller.dart';
import 'data/breadcrumb_sink.dart';
import 'data/delivery_api.dart';
import 'data/delivery_repository.dart';
import 'data/mock/mock_delivery_api.dart';
import 'data/route_service.dart';
import 'delivery_config.dart';
import 'domain/delivery.dart';

// Plain-Dart wiring for the delivery feature. Platform pieces (GPS, HTTP
// client, storage) are supplied as overrides by `delivery_bootstrap.dart`,
// and by fakes in tests.

final deliveryConfigProvider = Provider<DeliveryConfig>(
  (ref) => DeliveryConfig.fromEnvironment(),
);

final deliveryApiProvider = Provider<DeliveryApi>(
  (ref) => throw UnimplementedError('deliveryApiProvider must be overridden'),
);

/// Non-null in mock mode only, so the demo can show the code the recipient
/// would have received. Never set when talking to a real backend.
final mockDeliveryApiProvider = Provider<MockDeliveryApi?>((ref) => null);

final deliveryRepositoryProvider = Provider<DeliveryRepository>(
  (ref) => DeliveryRepository(ref.watch(deliveryApiProvider)),
);

/// How much location detail a caller needs, so each use gets the cheapest
/// GPS mode that does the job.
enum TrackingProfile {
  /// Online and waiting for requests: coarse, infrequent updates.
  dispatch,

  /// On a delivery: GPS accuracy, frequent updates for arrival detection.
  navigation,
}

typedef LocationSourceFactory = LocationSource Function(
  TrackingProfile profile,
);

final deliveryLocationSourceProvider = Provider<LocationSourceFactory>(
  (ref) => throw UnimplementedError(
    'deliveryLocationSourceProvider must be overridden',
  ),
);

final breadcrumbSinkProvider = Provider<BreadcrumbSink>(
  (ref) => const NoBreadcrumbs(),
);

final routeServiceProvider = Provider<RouteService>(
  (ref) => const StraightLineRouteService(),
);

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final availabilityProvider =
    NotifierProvider<AvailabilityController, AvailabilityState>(
      AvailabilityController.new,
    );

final activeDeliveryProvider =
    NotifierProvider<ActiveDeliveryController, ActiveDeliveryState>(
      ActiveDeliveryController.new,
    );

final offersProvider = NotifierProvider<OffersController, OffersState>(
  OffersController.new,
);

final historyProvider =
    NotifierProvider.autoDispose<HistoryController, HistoryState>(
      HistoryController.new,
    );

final summaryProvider = FutureProvider.autoDispose<PartnerSummary>(
  (ref) => ref.watch(deliveryRepositoryProvider).summary(),
);
