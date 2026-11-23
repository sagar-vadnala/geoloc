import 'location_record.dart';

/// Local persistence contract. The sync logic depends on this interface only,
/// which keeps it unit-testable without a database.
abstract class LocationStore {
  /// Saves a record. Returns `false` (and changes nothing) if a record with the
  /// same id already exists, so the same fix is never stored twice.
  Future<bool> insert(LocationRecord record);

  /// Oldest-first records that are `pending` and whose backoff has elapsed.
  Future<List<LocationRecord>> pendingBatch({
    required int limit,
    required DateTime now,
  });

  /// Marks the given ids as uploaded.
  Future<void> markSynced(Iterable<String> ids, {required DateTime at});

  /// Keeps the ids pending, bumps their attempt counter and delays the next try.
  Future<void> recordFailure(
    Iterable<String> ids, {
    required String error,
    required DateTime nextAttemptAt,
  });

  /// Gives up on the ids (server said the data is invalid). They stay on the
  /// device for inspection but are no longer retried automatically.
  Future<void> markRejected(Map<String, String> reasonById);

  /// Puts `failed` records back to `pending` (manual retry from the UI).
  Future<void> retryFailed();

  /// Earliest `next_attempt_at` among pending records, if any are delayed.
  Future<DateTime?> earliestRetryAt();

  Future<LocationCounts> counts();

  /// Emits the current snapshot immediately and again after every change.
  Stream<LocationSnapshot> watch({int recentLimit = 20});
}
