import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/location_record.dart';
import 'providers.dart';
import 'services/location_source.dart';

enum TrackingStatus { stopped, starting, tracking, error }

class TrackingState {
  const TrackingState({
    this.status = TrackingStatus.stopped,
    this.simulated = false,
    this.lastFix,
    this.message,
  });

  final TrackingStatus status;
  final bool simulated;
  final LocationFix? lastFix;
  final String? message;

  bool get isActive =>
      status == TrackingStatus.tracking || status == TrackingStatus.starting;

  TrackingState copyWith({
    TrackingStatus? status,
    bool? simulated,
    LocationFix? lastFix,
    String? Function()? message,
  }) => TrackingState(
    status: status ?? this.status,
    simulated: simulated ?? this.simulated,
    lastFix: lastFix ?? this.lastFix,
    message: message != null ? message() : this.message,
  );
}

/// Starts/stops location capture and persists every fix to SQLite *before*
/// anything else happens, so a crash or a missing network never loses data.
class TrackingController extends Notifier<TrackingState> {
  StreamSubscription<LocationFix>? _subscription;
  final _random = Random.secure();

  @override
  TrackingState build() {
    ref.onDispose(() => _subscription?.cancel());
    return const TrackingState();
  }

  void setSimulated(bool value) {
    if (state.isActive) return; // switch source only while stopped
    state = state.copyWith(simulated: value);
  }

  Future<void> start() async {
    if (state.isActive) return;
    // Make sure automatic sync is running.
    ref.read(syncCoordinatorProvider);

    state = state.copyWith(
      status: TrackingStatus.starting,
      message: () => null,
    );
    final source = ref.read(locationSourceFactoryProvider)(
      simulated: state.simulated,
    );
    _subscription = source.positions().listen(
      _onFix,
      onError: (Object error) {
        _subscription?.cancel();
        _subscription = null;
        state = state.copyWith(
          status: TrackingStatus.error,
          message: () => error.toString(),
        );
      },
      onDone: () {
        if (state.isActive) {
          state = state.copyWith(status: TrackingStatus.stopped);
        }
      },
    );
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    state = state.copyWith(status: TrackingStatus.stopped, message: () => null);
  }

  Future<void> _onFix(LocationFix fix) async {
    final previous = state.lastFix;
    final isRepeat =
        previous != null &&
        previous.timestamp == fix.timestamp &&
        previous.latitude == fix.latitude &&
        previous.longitude == fix.longitude;
    if (isRepeat) return;

    final record = LocationRecord(
      id: _newId(),
      latitude: fix.latitude,
      longitude: fix.longitude,
      accuracy: fix.accuracy,
      recordedAt: fix.timestamp.toUtc(),
    );
    try {
      await ref.read(locationStoreProvider).insert(record);
    } catch (e) {
      state = state.copyWith(
        status: TrackingStatus.error,
        message: () => 'Could not save location: $e',
      );
      return;
    }
    state = state.copyWith(
      status: TrackingStatus.tracking,
      lastFix: fix,
      message: () => null,
    );
    ref.read(syncCoordinatorProvider).requestSync();
  }

  /// Random 96-bit id plus a time prefix. Collisions are not a practical
  /// concern; the PRIMARY KEY would reject one anyway.
  String _newId() {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = List.generate(
      3,
      (_) => _random.nextInt(1 << 32).toRadixString(36),
    ).join();
    return '$time-$rand';
  }
}
