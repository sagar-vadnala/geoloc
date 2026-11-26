import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/delivery/domain/arrival_detector.dart';
import 'package:geoloc/feature/delivery/domain/geo.dart';
import 'package:geoloc/feature/location/domain/location_fix.dart';

const stop = GeoPoint(19.0760, 72.8777);
final t0 = DateTime.utc(2026, 1, 1, 10);

LocationFix at(GeoPoint p, int second, {double accuracy = 8}) => LocationFix(
  latitude: p.latitude,
  longitude: p.longitude,
  accuracy: accuracy,
  timestamp: t0.add(Duration(seconds: second)),
);

ArrivalDetector detector({ArrivalConfig config = const ArrivalConfig()}) =>
    ArrivalDetector(target: stop, config: config);

void main() {
  group('geo', () {
    test('distance is close to a known value', () {
      // Roughly 1.11 km per 0.01 degree of latitude.
      final d = stop.distanceTo(GeoPoint(stop.latitude + 0.01, stop.longitude));
      expect(d, closeTo(1112, 3));
    });

    test('offset and moveTowards agree with distance', () {
      final p = stop.offset(north: 300, east: 400);
      expect(stop.distanceTo(p), closeTo(500, 1));
      expect(p.moveTowards(stop, 200).distanceTo(stop), closeTo(300, 1));
      expect(p.moveTowards(stop, 10000), stop);
    });
  });

  test('a single reading inside the geofence is not an arrival', () {
    final d = detector();
    final progress = d.add(at(stop.offset(north: 10), 0));
    expect(progress.arrived, isFalse);
    expect(progress.insideCount, 1);
  });

  test('consecutive accurate readings over the dwell time confirm arrival', () {
    final d = detector();
    d.add(at(stop.offset(north: 30), 0));
    d.add(at(stop.offset(north: 24), 3));
    expect(
      d.add(at(stop.offset(north: 21), 4)).arrived,
      isFalse,
      reason: 'three fixes but only 4 s inside',
    );
    expect(d.add(at(stop.offset(north: 20), 6)).arrived, isTrue);
  });

  test('normal GPS jitter while standing still still counts as stopped', () {
    final d = detector();
    final jitter = [(6, -4), (-5, 3), (2, 7), (-7, -2), (4, -6)];
    var arrived = false;
    for (var i = 0; i < jitter.length; i++) {
      final (n, e) = jitter[i];
      arrived = d
          .add(at(stop.offset(north: 30.0 + n, east: e * 1.0), i * 2))
          .arrived;
    }
    expect(arrived, isTrue);
  });

  test('inaccurate readings are ignored and reported as weak signal', () {
    final d = detector();
    for (var s = 0; s < 10; s++) {
      final p = d.add(at(stop, s * 2, accuracy: 120));
      expect(p.arrived, isFalse);
      expect(p.weakSignal, isTrue);
      expect(p.insideCount, 0);
    }
  });

  test('an implausible jump does not count and does not reset progress', () {
    final d = detector();
    d.add(at(stop.offset(north: 20), 0));
    d.add(at(stop.offset(north: 25), 2));
    // 2 km away one second later: a GPS glitch, not movement.
    final glitch = d.add(at(stop.offset(north: 2000), 3));
    expect(glitch.lastQuality, FixQuality.outlier);
    expect(glitch.insideCount, 2);
    expect(d.add(at(stop.offset(north: 15), 6)).arrived, isTrue);
  });

  test('jitter just outside the radius keeps progress (hysteresis)', () {
    final d = detector();
    d.add(at(stop.offset(north: 60), 0));
    d.add(at(stop.offset(north: 85), 2)); // radius 75, margin 25
    expect(d.progress.insideCount, 1);
    d.add(at(stop.offset(north: 70), 4));
    expect(d.add(at(stop.offset(north: 65), 6)).arrived, isTrue);
  });

  test('leaving well beyond the radius starts over', () {
    final d = detector();
    d.add(at(stop.offset(north: 20), 0));
    d.add(at(stop.offset(north: 20), 2));
    d.add(at(stop.offset(north: 150), 8));
    expect(d.progress.insideCount, 0);
    expect(d.add(at(stop.offset(north: 20), 12)).arrived, isFalse);
  });

  test('driving past without stopping is not an arrival', () {
    final d = detector();
    // 12 m/s straight through the fence, one fix a second.
    for (var s = 0; s <= 20; s++) {
      final p = d.add(at(stop.offset(north: -120.0 + s * 12), s));
      expect(p.arrived, isFalse, reason: 'second $s');
    }
  });

  test('the radius is configurable, including per stop', () {
    const config = ArrivalConfig(radiusMeters: 30, minDwell: Duration.zero);
    final narrow = detector(config: config);
    for (var s = 0; s < 4; s++) {
      expect(narrow.add(at(stop.offset(north: 50), s)).arrived, isFalse);
    }
    final wide = detector(config: config.withRadius(150));
    wide.add(at(stop.offset(north: 120), 0));
    wide.add(at(stop.offset(north: 120), 1));
    expect(wide.add(at(stop.offset(north: 120), 2)).arrived, isTrue);
  });

  test('arrival stays confirmed until reset for a new stop', () {
    final d = detector(config: const ArrivalConfig(minDwell: Duration.zero));
    for (var s = 0; s < 3; s++) {
      d.add(at(stop, s));
    }
    expect(d.progress.arrived, isTrue);
    expect(d.add(at(stop.offset(north: 500), 30)).arrived, isTrue);

    final next = stop.offset(east: 2000);
    d.reset(target: next);
    expect(d.progress.arrived, isFalse);
    expect(d.target, next);
  });
}
