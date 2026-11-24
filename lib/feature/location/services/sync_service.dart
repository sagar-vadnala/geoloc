import 'dart:async';
import 'dart:math';

import '../data/location_api.dart';
import '../data/location_record.dart';
import '../data/location_store.dart';

/// Snapshot of what the sync engine is doing, for the UI.
class SyncState {
  const SyncState({this.isSyncing = false, this.lastSyncAt, this.lastError});

  final bool isSyncing;
  final DateTime? lastSyncAt;
  final String? lastError;

  SyncState copyWith({
    bool? isSyncing,
    DateTime? lastSyncAt,
    String? Function()? lastError,
  }) => SyncState(
    isSyncing: isSyncing ?? this.isSyncing,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    lastError: lastError != null ? lastError() : this.lastError,
  );
}

enum SyncOutcome {
  /// Every due record was handled.
  completed,

  /// Another sync is already in flight; this call did nothing.
  alreadyRunning,

  /// No network, nothing attempted.
  offline,

  /// A batch hit a retryable error. Records stay pending with backoff.
  failed,
}

typedef Backoff = Duration Function(int attempts);

/// 5s, 10s, 20s ... capped at 5 minutes.
Duration exponentialBackoff(int attempts) {
  final seconds = 5 * pow(2, min(attempts, 10)).toInt();
  return Duration(seconds: min(seconds, 300));
}

/// Uploads pending locations in batches.
///
/// Guarantees:
///  * single-flight: two overlapping calls never upload the same rows twice;
///  * a record leaves `pending` only after the server acknowledged it;
///  * the server dedupes by id, so a retry after a lost response is harmless.
class SyncService {
  SyncService({
    required this._store,
    required this._api,
    required this._isOnline,
    DateTime Function()? now,
    this.batchSize = 50,
    this._backoff = exponentialBackoff,
  }) : _now = now ?? DateTime.now;

  final LocationStore _store;
  final LocationApi _api;
  final Future<bool> Function() _isOnline;
  final DateTime Function() _now;
  final Backoff _backoff;
  final int batchSize;

  final _controller = StreamController<SyncState>.broadcast();
  SyncState _state = const SyncState();
  bool _running = false;

  SyncState get state => _state;
  Stream<SyncState> get states => _controller.stream;

  Future<SyncOutcome> sync() async {
    if (_running) return SyncOutcome.alreadyRunning;
    _running = true;
    try {
      if (!await _isOnline()) return SyncOutcome.offline;

      _emit(_state.copyWith(isSyncing: true));
      var outcome = SyncOutcome.completed;
      while (true) {
        final batch = await _store.pendingBatch(limit: batchSize, now: _now());
        if (batch.isEmpty) break;
        if (!await _uploadBatch(batch)) {
          outcome = SyncOutcome.failed;
          break;
        }
      }
      if (outcome == SyncOutcome.completed) {
        _emit(_state.copyWith(lastSyncAt: _now(), lastError: () => null));
      }
      return outcome;
    } finally {
      _running = false;
      _emit(_state.copyWith(isSyncing: false));
    }
  }

  /// Returns `true` if the loop may continue with the next batch.
  Future<bool> _uploadBatch(List<LocationRecord> batch) async {
    final ids = batch.map((r) => r.id).toSet();
    try {
      final result = await _api.uploadBatch(batch);

      final synced = {
        ...result.accepted,
        ...result.duplicates,
      }.where(ids.contains).toSet();
      final rejected = {
        for (final e in result.rejected.entries)
          if (ids.contains(e.key)) e.key: e.value,
      };
      await _store.markSynced(synced, at: _now());
      await _store.markRejected(rejected);

      // Anything the server did not mention was not acknowledged: keep it.
      final unacknowledged = ids
          .difference(synced)
          .difference(rejected.keys.toSet());
      if (unacknowledged.isNotEmpty) {
        await _fail(
          batch.where((r) => unacknowledged.contains(r.id)),
          'Server did not acknowledge ${unacknowledged.length} record(s)',
        );
        return false;
      }
      return true;
    } on ApiException catch (e) {
      if (e.retryable) {
        await _fail(batch, e.message);
        return false;
      }
      // The server refuses this payload; retrying cannot help.
      await _store.markRejected({for (final id in ids) id: e.message});
      _emit(_state.copyWith(lastError: () => e.message));
      return true;
    } catch (e) {
      await _fail(batch, e.toString());
      return false;
    }
  }

  Future<void> _fail(Iterable<LocationRecord> records, String error) async {
    final list = records.toList();
    final worst = list.map((r) => r.attempts).fold(0, max);
    await _store.recordFailure(
      list.map((r) => r.id),
      error: error,
      nextAttemptAt: _now().add(_backoff(worst)),
    );
    _emit(_state.copyWith(lastError: () => error));
  }

  void _emit(SyncState s) {
    _state = s;
    if (!_controller.isClosed) _controller.add(s);
  }

  Future<void> dispose() => _controller.close();
}
