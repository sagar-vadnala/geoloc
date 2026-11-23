import 'dart:async';

import '../data/location_store.dart';
import 'connectivity_service.dart';
import 'sync_service.dart';

/// Decides *when* to call [SyncService.sync]:
///  * at start-up,
///  * whenever connectivity comes back,
///  * shortly after new locations are saved (debounced),
///  * when the earliest backoff expires,
///  * and on a slow safety timer.
class SyncCoordinator {
  SyncCoordinator({
    required SyncService service,
    required LocationStore store,
    required ConnectivityService connectivity,
    this.debounce = const Duration(seconds: 2),
    this.safetyInterval = const Duration(minutes: 1),
  }) : _service = service,
       _store = store,
       _connectivity = connectivity;

  final SyncService _service;
  final LocationStore _store;
  final ConnectivityService _connectivity;
  final Duration debounce;
  final Duration safetyInterval;

  StreamSubscription<bool>? _connectivitySub;
  Timer? _debounceTimer;
  Timer? _retryTimer;
  Timer? _safetyTimer;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _connectivitySub = _connectivity.onChanged.listen((online) {
      if (online) requestSync(immediate: true);
    });
    _safetyTimer = Timer.periodic(safetyInterval, (_) => requestSync());
    requestSync(immediate: true);
  }

  void requestSync({bool immediate = false}) {
    if (!_started) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(immediate ? Duration.zero : debounce, _run);
  }

  Future<void> _run() async {
    await _service.sync();
    await _scheduleRetry();
  }

  Future<void> _scheduleRetry() async {
    _retryTimer?.cancel();
    final next = await _store.earliestRetryAt();
    if (next == null || !_started) return;
    var delay = next.difference(DateTime.now().toUtc());
    if (delay < const Duration(seconds: 1)) delay = const Duration(seconds: 1);
    _retryTimer = Timer(delay, () => requestSync(immediate: true));
  }

  void stop() {
    _started = false;
    _connectivitySub?.cancel();
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _safetyTimer?.cancel();
  }
}
