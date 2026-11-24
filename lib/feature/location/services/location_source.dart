import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// A position reported by a [LocationSource].
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
  });

  final double latitude;
  final double longitude;
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

/// Real GPS through the geolocator plugin.
///
/// Permission is requested up front by `LocationGate`. This only re-checks, so
/// a permission revoked mid-session shows up as a readable error.
class GeolocatorLocationSource implements LocationSource {
  GeolocatorLocationSource({this.interval = const Duration(seconds: 10)});

  /// Roughly how often a point is recorded. Updates are time-based rather than
  /// distance-based so a phone that isn't moving still records its position.
  final Duration interval;

  @override
  Stream<LocationFix> positions() async* {
    await _checkAccess();

    DateTime? last;
    yield* Geolocator.getPositionStream(locationSettings: _settings())
        .where((p) {
          // iOS ignores the interval and can report every second.
          if (last != null && p.timestamp.difference(last!) < interval ~/ 2) {
            return false;
          }
          last = p.timestamp;
          return true;
        })
        .map(
          (p) => LocationFix(
            latitude: p.latitude,
            longitude: p.longitude,
            accuracy: p.accuracy,
            timestamp: p.timestamp,
          ),
        );
  }

  Future<void> _checkAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationPermissionException(
        'Location is turned off on this phone.',
        serviceDisabled: true,
      );
    }
    switch (await Geolocator.checkPermission()) {
      case LocationPermission.whileInUse:
      case LocationPermission.always:
        return;
      case LocationPermission.deniedForever:
        throw const LocationPermissionException(
          'Location access is blocked. Allow it in Settings.',
          permanentlyDenied: true,
        );
      case LocationPermission.denied:
      case LocationPermission.unableToDetermine:
        throw const LocationPermissionException('Location access is needed.');
    }
  }

  LocationSettings _settings() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          intervalDuration: interval,
          // Runs updates in a foreground service so they keep coming while
          // the app is in the background. Android requires the notification.
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Recording your location',
            notificationText:
                'Points are saved on this phone and uploaded when you are '
                'online.',
            enableWakeLock: true,
            setOngoing: true,
          ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.high,
          activityType: ActivityType.otherNavigation,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
          allowBackgroundLocationUpdates: true,
        );
      default:
        return const LocationSettings(accuracy: LocationAccuracy.high);
    }
  }
}

/// Emits a random walk, so the whole pipeline can be demoed on an emulator or
/// at a desk without moving.
class SimulatedLocationSource implements LocationSource {
  SimulatedLocationSource({
    this.interval = const Duration(seconds: 3),
    this.startLatitude = 28.6139,
    this.startLongitude = 77.2090,
    Random? random,
  }) : _random = random ?? Random();

  final Duration interval;
  final double startLatitude;
  final double startLongitude;
  final Random _random;

  @override
  Stream<LocationFix> positions() {
    var lat = startLatitude;
    var lng = startLongitude;
    return Stream.periodic(interval, (_) {
      // ~ up to 20 m of drift per step.
      lat += (_random.nextDouble() - 0.5) * 0.0004;
      lng += (_random.nextDouble() - 0.5) * 0.0004;
      return LocationFix(
        latitude: lat,
        longitude: lng,
        accuracy: 5 + _random.nextDouble() * 10,
        timestamp: DateTime.now().toUtc(),
      );
    });
  }
}
