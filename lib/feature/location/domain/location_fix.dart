/// A position reported by a [LocationSource].
///
/// Kept free of plugin imports so features that consume positions (delivery
/// arrival detection, breadcrumbs) can be unit-tested on the plain Dart VM.
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
  });

  final double latitude;
  final double longitude;

  /// Radius of the 68% confidence circle in metres, if the platform gave one.
  final double? accuracy;
  final DateTime timestamp;
}

/// Where fixes come from: the real GPS or a simulator.
abstract class LocationSource {
  /// Starts producing fixes. Cancelling the subscription stops tracking.
  /// Errors (e.g. [LocationPermissionException]) are delivered on the stream.
  Stream<LocationFix> positions();
}

class LocationPermissionException implements Exception {
  const LocationPermissionException(
    this.message, {
    this.permanentlyDenied = false,
    this.serviceDisabled = false,
  });

  final String message;
  final bool permanentlyDenied;
  final bool serviceDisabled;

  @override
  String toString() => message;
}
