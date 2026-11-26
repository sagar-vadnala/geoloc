import '../../../core/ids.dart';
import '../../location/data/location_record.dart';
import '../../location/data/location_store.dart';
import '../../location/domain/location_fix.dart';

/// Receives the courier's positions during a delivery so the backend can
/// show progress to dispatch (and later the customer).
abstract class BreadcrumbSink {
  Future<void> record(String deliveryId, LocationFix fix);
}

class NoBreadcrumbs implements BreadcrumbSink {
  const NoBreadcrumbs();

  @override
  Future<void> record(String deliveryId, LocationFix fix) async {}
}

/// Reuses the app's offline-first location queue: points are written to
/// SQLite first and uploaded by the existing sync engine
/// (`POST /locations/batch`), so nothing is lost without a signal.
class StoreBreadcrumbSink implements BreadcrumbSink {
  StoreBreadcrumbSink(this._store, {required this.onRecorded});

  final LocationStore _store;

  /// Called after a point is saved, typically to schedule an upload.
  final void Function() onRecorded;

  @override
  Future<void> record(String deliveryId, LocationFix fix) async {
    final inserted = await _store.insert(
      LocationRecord(
        id: randomId(),
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracy: fix.accuracy,
        recordedAt: fix.timestamp.toUtc(),
        deliveryId: deliveryId,
      ),
    );
    if (inserted) onRecorded();
  }
}
