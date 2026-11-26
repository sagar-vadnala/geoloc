import '../../location/domain/location_fix.dart';
import 'geo.dart';

/// Tuning for [ArrivalDetector]. Defaults come from `DeliveryConfig`, and
/// the radius can be overridden per stop by the backend.
class ArrivalConfig {
  const ArrivalConfig({
    this.radiusMeters = 75,
    this.maxAccuracyMeters = 50,
    this.requiredFixes = 3,
    this.minDwell = const Duration(seconds: 5),
    this.exitMarginMeters = 25,
    this.maxSpeedMetersPerSecond = 60,
    this.maxArrivalSpeedMetersPerSecond = 3,
  }) : assert(radiusMeters > 0),
       assert(requiredFixes > 0);

  /// Geofence radius around the stop.
  final double radiusMeters;

  /// Fixes with a worse reported accuracy are ignored: a 200 m circle says
  /// nothing about whether the partner is inside a 75 m fence.
  final double maxAccuracyMeters;

  /// Consecutive usable fixes inside the fence needed to confirm arrival.
  final int requiredFixes;

  /// How long the partner must stay inside before arrival is confirmed, so a
  /// drive-past does not count.
  final Duration minDwell;

  /// Hysteresis: once inside, only leaving by this much more than the radius
  /// resets progress, so jitter at the edge doesn't restart the count.
  final double exitMarginMeters;

  /// Fixes implying a faster jump than this are treated as GPS outliers.
  final double maxSpeedMetersPerSecond;

  /// Average speed over the last [minDwell] must be below this (about
  /// 11 km/h), so driving through the fence without stopping is not an
  /// arrival. Measured over the window rather than fix to fix, so ordinary
  /// GPS jitter while standing still does not look like movement.
  final double maxArrivalSpeedMetersPerSecond;

  ArrivalConfig withRadius(double? radius) => radius == null || radius <= 0
      ? this
      : ArrivalConfig(
          radiusMeters: radius,
          maxAccuracyMeters: maxAccuracyMeters,
          requiredFixes: requiredFixes,
          minDwell: minDwell,
          exitMarginMeters: exitMarginMeters,
          maxSpeedMetersPerSecond: maxSpeedMetersPerSecond,
          maxArrivalSpeedMetersPerSecond: maxArrivalSpeedMetersPerSecond,
        );
}

enum FixQuality {
  /// Accurate enough and plausible: counted.
  good,

  /// Reported accuracy worse than [ArrivalConfig.maxAccuracyMeters].
  inaccurate,

  /// Implausible jump from the previous fix.
  outlier,
}

class ArrivalProgress {
  const ArrivalProgress({
    this.distanceMeters,
    this.insideCount = 0,
    this.arrived = false,
    this.lastQuality,
    this.lastAccuracyMeters,
  });

  /// Distance from the latest fix to the stop, whatever its quality.
  final double? distanceMeters;
  final int insideCount;
  final bool arrived;
  final FixQuality? lastQuality;
  final double? lastAccuracyMeters;

  bool get weakSignal => lastQuality == FixQuality.inaccurate;
}

/// Decides when the partner has reached a stop from a stream of noisy fixes.
///
/// A single reading never confirms arrival. The detector requires
/// [ArrivalConfig.requiredFixes] consecutive accurate fixes inside the
/// geofence spanning at least [ArrivalConfig.minDwell] while the partner has
/// essentially stopped. It ignores fixes whose accuracy is too poor, rejects
/// physically impossible jumps, and uses an exit margin so jitter at the
/// boundary doesn't reset progress. Once arrival is confirmed it stays
/// confirmed until [reset].
class ArrivalDetector {
  ArrivalDetector({required this._target, required this.config});

  final ArrivalConfig config;
  GeoPoint _target;
  LocationFix? _lastGood;
  final List<LocationFix> _inside = [];
  int _insideCount = 0;
  ArrivalProgress _progress = const ArrivalProgress();

  GeoPoint get target => _target;
  ArrivalProgress get progress => _progress;

  ArrivalProgress add(LocationFix fix) {
    final distance = _target.distanceTo(GeoPoint(fix.latitude, fix.longitude));
    if (_progress.arrived) {
      return _progress = _copy(distance: distance, quality: FixQuality.good);
    }

    final accuracy = fix.accuracy;
    if (accuracy != null && accuracy > config.maxAccuracyMeters) {
      return _progress = _copy(
        distance: distance,
        quality: FixQuality.inaccurate,
        accuracy: accuracy,
      );
    }

    final previous = _lastGood;
    if (previous != null) {
      final seconds =
          fix.timestamp.difference(previous.timestamp).inMilliseconds / 1000;
      final moved = distanceBetween(
        previous.latitude,
        previous.longitude,
        fix.latitude,
        fix.longitude,
      );
      if (seconds <= 0 && moved > config.radiusMeters ||
          seconds > 0 && moved / seconds > config.maxSpeedMetersPerSecond) {
        return _progress = _copy(
          distance: distance,
          quality: FixQuality.outlier,
          accuracy: accuracy,
        );
      }
    }
    _lastGood = fix;

    if (distance <= config.radiusMeters) {
      _insideCount++;
      _inside.add(fix);
      if (_inside.length > 120) _inside.removeAt(0);
    } else if (distance > config.radiusMeters + config.exitMarginMeters) {
      _inside.clear();
      _insideCount = 0;
    }
    // Between the radius and radius + margin: hold the current progress.

    final arrived =
        _insideCount >= config.requiredFixes &&
        _stoppedFor(fix, config.minDwell);

    return _progress = ArrivalProgress(
      distanceMeters: distance,
      insideCount: _insideCount,
      arrived: arrived,
      lastQuality: FixQuality.good,
      lastAccuracyMeters: accuracy,
    );
  }

  /// True if there is an inside fix at least [dwell] older than [latest]
  /// and the average speed since the most recent such fix is low.
  bool _stoppedFor(LocationFix latest, Duration dwell) {
    LocationFix? anchor;
    for (final f in _inside) {
      if (latest.timestamp.difference(f.timestamp) >= dwell) anchor = f;
    }
    if (anchor == null) return false;
    final seconds =
        latest.timestamp.difference(anchor.timestamp).inMilliseconds / 1000;
    if (seconds <= 0) return true;
    final moved = distanceBetween(
      anchor.latitude,
      anchor.longitude,
      latest.latitude,
      latest.longitude,
    );
    return moved / seconds <= config.maxArrivalSpeedMetersPerSecond;
  }

  /// Starts over, optionally for a new stop.
  void reset({GeoPoint? target}) {
    if (target != null) _target = target;
    _lastGood = null;
    _inside.clear();
    _insideCount = 0;
    _progress = const ArrivalProgress();
  }

  ArrivalProgress _copy({
    required double distance,
    required FixQuality quality,
    double? accuracy,
  }) => ArrivalProgress(
    distanceMeters: distance,
    insideCount: _insideCount,
    arrived: _progress.arrived,
    lastQuality: quality,
    lastAccuracyMeters: accuracy,
  );
}
