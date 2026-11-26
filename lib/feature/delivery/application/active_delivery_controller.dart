import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../location/domain/location_fix.dart';
import '../data/delivery_api.dart';
import '../data/delivery_repository.dart';
import '../data/route_service.dart';
import '../delivery_config.dart';
import '../delivery_providers.dart';
import '../domain/arrival_detector.dart';
import '../domain/delivery.dart';
import '../domain/delivery_status.dart';
import '../domain/geo.dart';
import '../services/route_simulator.dart';

enum LocationIssue {
  /// Location is switched off on the phone.
  serviceDisabled,
  permissionDenied,

  /// No position yet after starting tracking.
  noFix,

  /// Positions arrive but are too inaccurate for arrival detection.
  weakSignal,

  /// The location stream failed for another reason.
  unavailable,
}

enum ActiveNotice {
  /// The backend no longer lists this delivery for the partner.
  removed,
}

class ActiveDeliveryState {
  const ActiveDeliveryState({
    this.delivery,
    this.loading = false,
    this.loadError,
    this.pendingAction,
    this.actionError,
    this.failedAction,
    this.lastFix,
    this.arrival,
    this.locationIssue,
    this.route,
    this.simulateMovement = false,
    this.notice,
  });

  /// As last returned by the backend. Kept after completion or cancellation
  /// so the screen can show the outcome until the partner dismisses it.
  final Delivery? delivery;
  final bool loading;
  final DeliveryException? loadError;

  /// Set while a request for this action is in flight; all actions are
  /// disabled meanwhile, which rules out double submissions.
  final DeliveryAction? pendingAction;
  final DeliveryException? actionError;
  final DeliveryAction? failedAction;
  final LocationFix? lastFix;
  final ArrivalProgress? arrival;
  final LocationIssue? locationIssue;
  final RoutePath? route;
  final bool simulateMovement;
  final ActiveNotice? notice;

  bool get hasActive => delivery?.status.isActive ?? false;

  /// Offers must not be shown while a delivery is active or still loading.
  bool get blocksOffers => loading || hasActive;

  double? get distanceToStop {
    final target = delivery?.currentStop?.location;
    final fix = lastFix;
    if (target == null || fix == null) return null;
    return target.distanceTo(GeoPoint(fix.latitude, fix.longitude));
  }

  ActiveDeliveryState copyWith({
    Object? delivery = _keep,
    bool? loading,
    Object? loadError = _keep,
    Object? pendingAction = _keep,
    Object? actionError = _keep,
    Object? failedAction = _keep,
    Object? lastFix = _keep,
    Object? arrival = _keep,
    Object? locationIssue = _keep,
    Object? route = _keep,
    bool? simulateMovement,
    Object? notice = _keep,
  }) => ActiveDeliveryState(
    delivery: delivery == _keep ? this.delivery : delivery as Delivery?,
    loading: loading ?? this.loading,
    loadError: loadError == _keep
        ? this.loadError
        : loadError as DeliveryException?,
    pendingAction: pendingAction == _keep
        ? this.pendingAction
        : pendingAction as DeliveryAction?,
    actionError: actionError == _keep
        ? this.actionError
        : actionError as DeliveryException?,
    failedAction: failedAction == _keep
        ? this.failedAction
        : failedAction as DeliveryAction?,
    lastFix: lastFix == _keep ? this.lastFix : lastFix as LocationFix?,
    arrival: arrival == _keep ? this.arrival : arrival as ArrivalProgress?,
    locationIssue: locationIssue == _keep
        ? this.locationIssue
        : locationIssue as LocationIssue?,
    route: route == _keep ? this.route : route as RoutePath?,
    simulateMovement: simulateMovement ?? this.simulateMovement,
    notice: notice == _keep ? this.notice : notice as ActiveNotice?,
  );
}

const _keep = Object();

/// Owns the partner's current delivery.
///
/// Location tracking is tied to the delivery, not to a screen: it starts when
/// a delivery becomes active, keeps running while the partner is in another
/// app or screen (needed for arrival detection while navigating), and stops
/// as soon as the delivery is finished. Every state change comes from a
/// backend response; the app never moves a delivery forward on its own.
class ActiveDeliveryController extends Notifier<ActiveDeliveryState> {
  static const noFixAfter = Duration(seconds: 20);
  static const locationRetryAfter = Duration(seconds: 10);
  static const arrivalRetryAfter = Duration(seconds: 10);
  static const breadcrumbEvery = Duration(seconds: 15);
  static const breadcrumbDistance = 30.0;

  StreamSubscription<LocationFix>? _location;
  String? _trackingKey;
  Timer? _noFixTimer;
  Timer? _locationRetry;
  Timer? _refreshTimer;
  ArrivalDetector? _detector;
  String? _detectorKey;
  DateTime? _arrivalRetryAt;
  String? _routeKey;
  LocationFix? _lastBreadcrumb;

  @override
  ActiveDeliveryState build() {
    ref.onDispose(_stopAll);
    Future.microtask(refresh);
    return const ActiveDeliveryState(loading: true);
  }

  DeliveryRepository get _repo => ref.read(deliveryRepositoryProvider);
  DeliveryConfig get _config => ref.read(deliveryConfigProvider);
  DateTime _now() => ref.read(clockProvider)();

  /// Re-reads the delivery from the backend (the source of truth): on start,
  /// periodically while active, and after a conflict.
  Future<void> refresh() async {
    if (!ref.mounted || state.pendingAction != null) return;
    final current = state.delivery;
    try {
      if (current != null && current.status.isActive) {
        final latest = await _repo.delivery(current.id);
        if (!ref.mounted || state.pendingAction != null) return;
        _apply(latest);
      } else if (current == null) {
        final active = await _repo.activeDelivery();
        if (!ref.mounted || state.pendingAction != null) return;
        _apply(active);
      }
      state = state.copyWith(loading: false, loadError: null);
    } on DeliveryException catch (e) {
      if (!ref.mounted) return;
      if (current != null &&
          (e.code == DeliveryErrorCode.notFound ||
              e.code == DeliveryErrorCode.forbidden)) {
        _apply(null);
        state = state.copyWith(loading: false, notice: ActiveNotice.removed);
        return;
      }
      state = state.copyWith(loading: false, loadError: e);
    }
  }

  /// Takes over a delivery the partner has just accepted.
  void adopt(Delivery delivery) {
    _apply(delivery);
    state = state.copyWith(loading: false, loadError: null, notice: null);
  }

  /// Clears a finished delivery from the screen.
  void dismiss() {
    final d = state.delivery;
    if (d != null && d.status.isActive) return;
    _apply(null);
    state = state.copyWith(notice: null, actionError: null, failedAction: null);
  }

  Future<bool> markArrived() {
    final d = state.delivery;
    final stop = d?.status.currentStop;
    final action = d == null
        ? null
        : DeliveryTransitions.arrivalActionFor(d.status);
    if (d == null || stop == null || action == null) return Future.value(false);
    return _perform(
      action,
      () => _repo.reportArrival(
        d.id,
        stop,
        detection: ArrivalDetection.manual,
        fix: state.lastFix,
      ),
    );
  }

  Future<bool> confirmPickup() {
    final d = state.delivery;
    if (d == null) return Future.value(false);
    return _perform(
      DeliveryAction.confirmPickup,
      () => _repo.confirmPickup(d.id),
    );
  }

  Future<bool> completeWithOtp(String code) {
    final d = state.delivery;
    if (d == null) return Future.value(false);
    return _perform(
      DeliveryAction.complete,
      () => _repo.completeWithOtp(d.id, code, fix: state.lastFix),
    );
  }

  /// Mock mode only: replace GPS with a simulated drive to the current stop.
  void setSimulateMovement(bool value) {
    if (!_config.isMock || value == state.simulateMovement) return;
    state = state.copyWith(simulateMovement: value);
    _trackingKey = null;
    _syncTracking();
  }

  void retryLocation() {
    _trackingKey = null;
    state = state.copyWith(locationIssue: null);
    _syncTracking();
  }

  void clearActionError() =>
      state = state.copyWith(actionError: null, failedAction: null);

  // --- actions -------------------------------------------------------------

  Future<bool> _perform(
    DeliveryAction action,
    Future<Delivery> Function() request,
  ) async {
    final d = state.delivery;
    if (d == null ||
        state.pendingAction != null ||
        !DeliveryTransitions.allows(d.status, action)) {
      return false;
    }
    state = state.copyWith(
      pendingAction: action,
      actionError: null,
      failedAction: null,
    );
    try {
      final updated = await request();
      if (!ref.mounted) return true;
      state = state.copyWith(pendingAction: null);
      _apply(updated);
      if (updated.status == DeliveryStatus.completed) {
        ref.invalidate(summaryProvider);
        ref.invalidate(historyProvider);
      }
      return true;
    } on DeliveryException catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(
        pendingAction: null,
        actionError: e,
        failedAction: action,
      );
      switch (e.code) {
        case DeliveryErrorCode.invalidTransition:
        case DeliveryErrorCode.notFound:
          // Our copy is stale; the backend decides what happens next.
          unawaited(refresh());
        case DeliveryErrorCode.tooFarFromStop:
          _detector?.reset();
          state = state.copyWith(arrival: null);
        default:
          break;
      }
      return false;
    }
  }

  Future<void> _reportAutoArrival(LocationFix fix) async {
    final d = state.delivery;
    final stop = d?.status.currentStop;
    final action = d == null
        ? null
        : DeliveryTransitions.arrivalActionFor(d.status);
    if (d == null || stop == null || action == null) return;
    if (state.pendingAction != null) return;
    final retryAt = _arrivalRetryAt;
    if (retryAt != null && _now().isBefore(retryAt)) return;

    final ok = await _perform(
      action,
      () => _repo.reportArrival(
        d.id,
        stop,
        detection: ArrivalDetection.auto,
        fix: fix,
      ),
    );
    if (!ok) _arrivalRetryAt = _now().add(arrivalRetryAfter);
  }

  // --- state application ---------------------------------------------------

  void _apply(Delivery? delivery) {
    state = state.copyWith(delivery: delivery);
    _syncDetector(delivery);
    _syncTracking();
    _syncRefreshTimer();
  }

  void _syncDetector(Delivery? d) {
    final stop = d?.currentStop;
    final key = d != null && d.status.isEnRoute && stop?.location != null
        ? '${d.id}:${stop!.kind.wire}'
        : null;
    if (key == _detectorKey) return;
    _detectorKey = key;
    _arrivalRetryAt = null;
    _detector = key == null
        ? null
        : ArrivalDetector(
            target: stop!.location!,
            config: _config.arrival.withRadius(stop.geofenceRadiusMeters),
          );
    if (key != _routeKey) {
      _routeKey = null;
      state = state.copyWith(arrival: null, route: null);
    }
  }

  void _syncTracking() {
    final d = state.delivery;
    final stop = d?.currentStop;
    final active = d != null && d.status.isActive;
    final simulate = active && state.simulateMovement && stop?.location != null;
    final key = !active
        ? null
        : simulate
        ? 'sim:${d.id}:${stop!.kind.wire}'
        : 'gps:${d.id}';
    if (key == _trackingKey) return;

    _location?.cancel();
    _location = null;
    _noFixTimer?.cancel();
    _locationRetry?.cancel();
    _trackingKey = key;
    if (key == null) {
      _lastBreadcrumb = null;
      state = state.copyWith(locationIssue: null);
      return;
    }

    final LocationSource source;
    if (simulate) {
      final target = stop!.location!;
      final fix = state.lastFix;
      source = RouteSimulator(
        start: fix != null
            ? GeoPoint(fix.latitude, fix.longitude)
            : target.offset(north: 700, east: 500),
        target: target,
        now: _now,
      );
    } else {
      source = ref.read(deliveryLocationSourceProvider)(
        TrackingProfile.navigation,
      );
    }
    _location = source.positions().listen(_onFix, onError: _onLocationError);
    _noFixTimer = Timer(noFixAfter, () {
      if (ref.mounted && state.lastFix == null) {
        state = state.copyWith(locationIssue: LocationIssue.noFix);
      }
    });
  }

  void _onFix(LocationFix fix) {
    if (!ref.mounted) return;
    _noFixTimer?.cancel();
    final d = state.delivery;
    if (d == null) return;

    final detector = _detector;
    final progress = detector != null && d.status.isEnRoute
        ? detector.add(fix)
        : null;
    state = state.copyWith(
      lastFix: fix,
      arrival: progress ?? state.arrival,
      locationIssue: progress?.weakSignal == true
          ? LocationIssue.weakSignal
          : null,
    );

    _recordBreadcrumb(d.id, fix);
    _maybeLoadRoute(d, fix);
    if (progress?.arrived == true) unawaited(_reportAutoArrival(fix));
  }

  void _onLocationError(Object error) {
    if (!ref.mounted) return;
    final issue = switch (error) {
      LocationPermissionException(serviceDisabled: true) =>
        LocationIssue.serviceDisabled,
      LocationPermissionException() => LocationIssue.permissionDenied,
      _ => LocationIssue.unavailable,
    };
    _location?.cancel();
    _location = null;
    _noFixTimer?.cancel();
    state = state.copyWith(locationIssue: issue);
    // Picks tracking up again once the partner fixes it in Settings.
    _locationRetry?.cancel();
    _locationRetry = Timer(locationRetryAfter, () {
      if (!ref.mounted) return;
      _trackingKey = null;
      _syncTracking();
    });
  }

  void _recordBreadcrumb(String deliveryId, LocationFix fix) {
    final last = _lastBreadcrumb;
    if (last != null) {
      final elapsed = fix.timestamp.difference(last.timestamp);
      final moved = distanceBetween(
        last.latitude,
        last.longitude,
        fix.latitude,
        fix.longitude,
      );
      if (elapsed < breadcrumbEvery && moved < breadcrumbDistance) return;
    }
    _lastBreadcrumb = fix;
    unawaited(
      ref
          .read(breadcrumbSinkProvider)
          .record(deliveryId, fix)
          .catchError((Object _) {}),
    );
  }

  void _maybeLoadRoute(Delivery d, LocationFix fix) {
    final stop = d.currentStop;
    if (!d.status.isEnRoute || stop?.location == null) return;
    final key = '${d.id}:${stop!.kind.wire}';
    if (_routeKey == key) return;
    _routeKey = key;
    ref
        .read(routeServiceProvider)
        .route(GeoPoint(fix.latitude, fix.longitude), stop.location!)
        .then((path) {
          if (ref.mounted && _routeKey == key) {
            state = state.copyWith(route: path);
          }
        });
  }

  void _syncRefreshTimer() {
    if (state.hasActive) {
      _refreshTimer ??= Timer.periodic(
        _config.activeRefreshInterval,
        (_) => refresh(),
      );
    } else {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  void _stopAll() {
    _location?.cancel();
    _noFixTimer?.cancel();
    _locationRetry?.cancel();
    _refreshTimer?.cancel();
  }
}
