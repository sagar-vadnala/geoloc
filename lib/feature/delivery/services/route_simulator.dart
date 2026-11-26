import 'dart:async';
import 'dart:math';

import '../../location/domain/location_fix.dart';
import '../domain/geo.dart';

/// Drives a fake courier towards [target] so the delivery flow, including
/// arrival detection, can be demoed on an emulator. Mock mode only.
///
/// Every [outlierEvery]-th fix is deliberately bad (large accuracy radius
/// and a jump) to show that the arrival detector ignores such readings.
class RouteSimulator implements LocationSource {
  RouteSimulator({
    required this.start,
    required this.target,
    this.speedMetersPerSecond = 14,
    this.interval = const Duration(seconds: 1),
    this.outlierEvery = 12,
    Random? random,
    DateTime Function()? now,
  }) : _random = random ?? Random(),
       _now = now ?? DateTime.now;

  final GeoPoint start;
  final GeoPoint target;
  final double speedMetersPerSecond;
  final Duration interval;
  final int outlierEvery;
  final Random _random;
  final DateTime Function() _now;

  @override
  Stream<LocationFix> positions() {
    var position = start;
    var tick = 0;
    final step = speedMetersPerSecond * interval.inMilliseconds / 1000;
    return Stream.periodic(interval, (_) {
      tick++;
      position = position.moveTowards(target, step);
      final jitter = position.offset(
        north: (_random.nextDouble() - 0.5) * 8,
        east: (_random.nextDouble() - 0.5) * 8,
      );
      if (outlierEvery > 0 && tick % outlierEvery == 0) {
        final off = jitter.offset(north: 120, east: -90);
        return LocationFix(
          latitude: off.latitude,
          longitude: off.longitude,
          accuracy: 90,
          timestamp: _now(),
        );
      }
      return LocationFix(
        latitude: jitter.latitude,
        longitude: jitter.longitude,
        accuracy: 5 + _random.nextDouble() * 10,
        timestamp: _now(),
      );
    });
  }
}
