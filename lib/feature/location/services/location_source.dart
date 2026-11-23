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
class GeolocatorLocationSource implements LocationSource {
  GeolocatorLocationSource({this.distanceFilterMeters = 10});

  /// Minimum movement before a new fix is delivered. Saves battery and avoids
  /// storing hundreds of identical points while standing still.
  final int distanceFilterMeters;

  @override
  Stream<LocationFix> positions() async* {
    await _ensurePermission();
    yield* Geolocator.getPositionStream(locationSettings: _settings()).map(
      (p) => LocationFix(
        latitude: p.latitude,
        longitude: p.longitude,
        accuracy: p.accuracy,
        timestamp: p.timestamp,
      ),
    );
  }

  Future<void> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationPermissionException(
        'Location services are turned off. Enable GPS and try again.',
        serviceDisabled: true,
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationPermissionException(
        'Location permission is permanently denied. Enable it in system settings.',
        permanentlyDenied: true,
      );
    }
    if (permission == LocationPermission.denied) {
      throw const LocationPermissionException('Location permission denied.');
    }
  }

  LocationSettings _settings() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: distanceFilterMeters,
          intervalDuration: const Duration(seconds: 5),
          // A foreground service keeps the process (and GPS) alive when the app
          // is in the background. Android requires a visible notification.
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Geoloc is tracking your location',
            notificationText:
                'Locations are saved on this device and synced '
                'when you are online.',
            enableWakeLock: true,
          ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.high,
          activityType: ActivityType.otherNavigation,
          distanceFilter: distanceFilterMeters,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
          allowBackgroundLocationUpdates: true,
        );
      default:
        return LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: distanceFilterMeters,
        );
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
