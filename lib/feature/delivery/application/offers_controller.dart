import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../location/domain/location_fix.dart';
import '../data/delivery_api.dart';
import '../delivery_providers.dart';
import '../domain/delivery.dart';
import '../domain/geo.dart';

/// An offer plus the local deadline computed when it first arrived.
class OfferView {
  const OfferView(this.offer, this.deadline, this.window);

  final DeliveryOffer offer;
  final DateTime deadline;

  /// The full response window as first received, for the countdown bar.
  final Duration window;

  Duration remaining(DateTime now) {
    final left = deadline.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  bool isExpired(DateTime now) => !now.isBefore(deadline);
}

enum OffersNotice {
  /// The partner tried to accept after the timer ran out.
  expired,

  /// The backend says the offer is gone (expired, cancelled, taken).
  unavailable,

  /// Accepting failed for a reason that may go away (no connection).
  acceptFailed,
}

class OffersState {
  const OffersState({
    this.offers = const [],
    this.listening = false,
    this.loaded = false,
    this.error,
    this.acceptingId,
    this.notice,
    this.lastFix,
  });

  final List<OfferView> offers;

  /// Polling is running (online, no active delivery).
  final bool listening;

  /// At least one poll has finished since listening started.
  final bool loaded;

  /// The latest poll failed. Offers from earlier polls are kept.
  final DeliveryException? error;
  final String? acceptingId;
  final OffersNotice? notice;
  final LocationFix? lastFix;

  OffersState copyWith({
    List<OfferView>? offers,
    bool? listening,
    bool? loaded,
    Object? error = _keep,
    Object? acceptingId = _keep,
    Object? notice = _keep,
    LocationFix? lastFix,
  }) => OffersState(
    offers: offers ?? this.offers,
    listening: listening ?? this.listening,
    loaded: loaded ?? this.loaded,
    error: error == _keep ? this.error : error as DeliveryException?,
    acceptingId: acceptingId == _keep
        ? this.acceptingId
        : acceptingId as String?,
    notice: notice == _keep ? this.notice : notice as OffersNotice?,
    lastFix: lastFix ?? this.lastFix,
  );
}

const _keep = Object();

/// Incoming delivery requests.
///
/// Polls the backend while the partner is online and has no active delivery,
/// and keeps a coarse location subscription for the distance to pickup and
/// as a heartbeat. Push notifications should replace polling in production;
/// the rest of this class would stay the same.
class OffersController extends Notifier<OffersState> {
  /// How long an offer that ran out stays on screen, marked as expired.
  static const linger = Duration(seconds: 3);

  Timer? _timer;
  Duration? _interval;
  StreamSubscription<LocationFix>? _location;
  bool _inFlight = false;

  @override
  OffersState build() {
    ref.listen(availabilityProvider.select((s) => s.online), (_, _) => _sync());
    ref.listen(
      activeDeliveryProvider.select((s) => s.blocksOffers),
      (_, _) => _sync(),
    );
    ref.onDispose(_stop);
    Future.microtask(_sync);
    return const OffersState();
  }

  DateTime _now() => ref.read(clockProvider)();

  bool get _shouldListen =>
      ref.read(availabilityProvider).online &&
      !ref.read(activeDeliveryProvider).blocksOffers;

  void _sync() {
    if (!ref.mounted) return;
    if (_shouldListen) {
      if (_timer == null) _start();
    } else if (_timer != null || state.offers.isNotEmpty) {
      _stop();
      state = const OffersState();
    }
  }

  void _start() {
    state = state.copyWith(listening: true, loaded: false, error: null);
    _location = ref
        .read(deliveryLocationSourceProvider)(TrackingProfile.dispatch)
        .positions()
        .listen(
          (fix) => state = state.copyWith(lastFix: fix),
          // Location problems are surfaced by the permission gate; offers
          // still work without a position.
          onError: (Object _) {},
        );
    _schedule(ref.read(deliveryConfigProvider).offerPollInterval);
    poll();
  }

  void _schedule(Duration interval) {
    if (_interval == interval && _timer != null) return;
    _timer?.cancel();
    _interval = interval;
    _timer = Timer.periodic(interval, (_) => poll());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _interval = null;
    _location?.cancel();
    _location = null;
  }

  Future<void> poll() async {
    if (_inFlight || _timer == null) return;
    _inFlight = true;
    try {
      final fix = state.lastFix;
      final result = await ref
          .read(deliveryRepositoryProvider)
          .offers(
            at: fix == null ? null : GeoPoint(fix.latitude, fix.longitude),
          );
      if (!ref.mounted || _timer == null) return;

      final now = _now();
      final known = {for (final o in state.offers) o.offer.id: o};
      final fresh = [
        for (final offer in result.offers)
          // Keep the first deadline: re-polling must not extend the window.
          OfferView(
            offer,
            known[offer.id]?.deadline ?? now.add(offer.expiresIn),
            known[offer.id]?.window ?? offer.expiresIn,
          ),
      ];
      final freshIds = {for (final o in fresh) o.offer.id};
      final lingering = state.offers.where(
        (o) =>
            !freshIds.contains(o.offer.id) &&
            (o.offer.id == state.acceptingId ||
                (o.isExpired(now) && now.difference(o.deadline) < linger)),
      );
      state = state.copyWith(
        offers: [...fresh, ...lingering],
        loaded: true,
        error: null,
      );
      final hint = result.pollAfter;
      if (hint != null && hint > Duration.zero) _schedule(hint);
    } on DeliveryException catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(loaded: true, error: e);
    } finally {
      _inFlight = false;
    }
  }

  /// Accepts [offerId]. Returns true when the delivery is now active.
  Future<bool> accept(String offerId) async {
    if (state.acceptingId != null) return false;
    final view = state.offers.where((o) => o.offer.id == offerId).firstOrNull;
    if (view == null) return false;
    if (view.isExpired(_now())) {
      state = state.copyWith(notice: OffersNotice.expired);
      return false;
    }

    state = state.copyWith(acceptingId: offerId, notice: null);
    try {
      final delivery = await ref
          .read(deliveryRepositoryProvider)
          .accept(offerId);
      if (!ref.mounted) return true;
      // Clears the offers via the blocksOffers listener.
      ref.read(activeDeliveryProvider.notifier).adopt(delivery);
      state = state.copyWith(acceptingId: null);
      return true;
    } on DeliveryException catch (e) {
      if (!ref.mounted) return false;
      final gone = const {
        DeliveryErrorCode.offerUnavailable,
        DeliveryErrorCode.invalidTransition,
        DeliveryErrorCode.notFound,
      }.contains(e.code);
      state = state.copyWith(
        acceptingId: null,
        notice: gone ? OffersNotice.unavailable : OffersNotice.acceptFailed,
        offers: gone
            ? state.offers.where((o) => o.offer.id != offerId).toList()
            : null,
      );
      // A conflict can mean a delivery is already active (another device).
      if (e.code == DeliveryErrorCode.invalidTransition) {
        unawaited(ref.read(activeDeliveryProvider.notifier).refresh());
      }
      return false;
    }
  }

  /// Removes the offer at once and tells the backend in the background. If
  /// that fails the offer simply expires on the server.
  void reject(String offerId) {
    if (state.acceptingId == offerId) return;
    state = state.copyWith(
      offers: state.offers.where((o) => o.offer.id != offerId).toList(),
    );
    unawaited(
      ref
          .read(deliveryRepositoryProvider)
          .reject(offerId)
          .catchError((Object _) {}),
    );
  }

  void clearNotice() => state = state.copyWith(notice: null);
}
