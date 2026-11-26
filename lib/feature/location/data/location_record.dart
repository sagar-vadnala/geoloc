/// Lifecycle of a stored location with respect to the server.
enum SyncStatus {
  /// Saved locally, not yet acknowledged by the server (will be retried).
  pending,

  /// Acknowledged by the server. Never uploaded again.
  synced,

  /// Permanently rejected by the server (e.g. invalid payload). Not retried
  /// automatically so one bad record can never block the queue.
  failed;

  static SyncStatus fromName(String name) =>
      SyncStatus.values.firstWhere((s) => s.name == name);
}

/// A single GPS fix as stored in SQLite and sent to the API.
class LocationRecord {
  const LocationRecord({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.recordedAt,
    this.accuracy,
    this.status = SyncStatus.pending,
    this.attempts = 0,
    this.lastError,
    this.nextAttemptAt,
    this.syncedAt,
    this.deliveryId,
  });

  /// Client-generated unique id. It is the idempotency key: the server uses it
  /// to ignore a record it has already stored, so retries never duplicate.
  final String id;
  final double latitude;
  final double longitude;
  final double? accuracy;

  /// When the fix was captured on the device (UTC).
  final DateTime recordedAt;

  final SyncStatus status;
  final int attempts;
  final String? lastError;

  /// Earliest time another upload may be attempted (exponential backoff).
  final DateTime? nextAttemptAt;
  final DateTime? syncedAt;

  /// Set when the point was recorded during a delivery, so the backend can
  /// show the courier's progress for that order.
  final String? deliveryId;

  /// Payload sent to the server. Local bookkeeping columns are not included.
  Map<String, dynamic> toApiJson() => {
    'id': id,
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    if (deliveryId != null) 'deliveryId': deliveryId,
  };

  Map<String, Object?> toDb() => {
    'id': id,
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'recorded_at': recordedAt.toUtc().millisecondsSinceEpoch,
    'status': status.name,
    'attempts': attempts,
    'last_error': lastError,
    'next_attempt_at': nextAttemptAt?.toUtc().millisecondsSinceEpoch,
    'synced_at': syncedAt?.toUtc().millisecondsSinceEpoch,
    'delivery_id': deliveryId,
  };

  factory LocationRecord.fromDb(Map<String, Object?> row) {
    DateTime? ms(Object? v) => v == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(v as int, isUtc: true);
    return LocationRecord(
      id: row['id'] as String,
      latitude: (row['latitude'] as num).toDouble(),
      longitude: (row['longitude'] as num).toDouble(),
      accuracy: (row['accuracy'] as num?)?.toDouble(),
      recordedAt: ms(row['recorded_at'])!,
      status: SyncStatus.fromName(row['status'] as String),
      attempts: row['attempts'] as int,
      lastError: row['last_error'] as String?,
      nextAttemptAt: ms(row['next_attempt_at']),
      syncedAt: ms(row['synced_at']),
      deliveryId: row['delivery_id'] as String?,
    );
  }
}

/// Aggregate numbers shown on the tracking screen.
class LocationCounts {
  const LocationCounts({this.pending = 0, this.synced = 0, this.failed = 0});

  final int pending;
  final int synced;
  final int failed;

  int get total => pending + synced + failed;

  @override
  bool operator ==(Object other) =>
      other is LocationCounts &&
      other.pending == pending &&
      other.synced == synced &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(pending, synced, failed);
}

/// Everything the UI needs from storage in one emission.
class LocationSnapshot {
  const LocationSnapshot({
    this.counts = const LocationCounts(),
    this.recent = const [],
  });

  final LocationCounts counts;
  final List<LocationRecord> recent;
}
