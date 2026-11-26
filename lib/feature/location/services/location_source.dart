import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../domain/location_fix.dart';

export '../domain/location_fix.dart';

/// Real GPS through the geolocator plugin.
///
/// Permission is requested up front by `LocationGate`. This only re-checks, so
/// a permission revoked mid-session shows up as a readable error.
class GeolocatorLocationSource implements LocationSource {
  GeolocatorLocationSource({
    this.interval = const Duration(seconds: 10),
    this.highAccuracy = true,
    this.distanceFilterMeters = 0,
    this.notificationTitle = 'Recording your location',
    this.notificationText =
        'Points are saved on this phone and uploaded when you are online.',
  });

  /// Roughly how often a point is recorded. With the default distance filter
  /// of 0 updates are time-based, so a phone that isn't moving still records
  /// its position.
  final Duration interval;

  /// GPS-level accuracy. When false the OS may use Wi-Fi/cell positioning
  /// (roughly 100 m), which uses noticeably less battery.
  final bool highAccuracy;

  /// Minimum movement in metres before the OS reports a new position.
  final int distanceFilterMeters;

  /// Text of the Android foreground-service notification shown while active.
  final String notificationTitle;
  final String notificationText;

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
          accuracy: _accuracy,
          distanceFilter: distanceFilterMeters,
          intervalDuration: interval,
          // Runs updates in a foreground service so they keep coming while
          // the app is in the background. Android requires the notification.
          foregroundNotificationConfig: ForegroundNotificationConfig(
            notificationTitle: notificationTitle,
            notificationText: notificationText,
            enableWakeLock: true,
            setOngoing: true,
          ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: _accuracy,
          activityType: ActivityType.otherNavigation,
          distanceFilter: distanceFilterMeters,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
          allowBackgroundLocationUpdates: true,
        );
      default:
        return LocationSettings(
          accuracy: _accuracy,
          distanceFilter: distanceFilterMeters,
        );
    }
  }

  LocationAccuracy get _accuracy =>
      highAccuracy ? LocationAccuracy.high : LocationAccuracy.medium;
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
