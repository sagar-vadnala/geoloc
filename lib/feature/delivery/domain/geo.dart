import 'dart:math' as math;

const _earthRadiusMeters = 6371008.8;

/// A WGS84 coordinate.
class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  factory GeoPoint.fromJson(Map<String, dynamic> json) => GeoPoint(
    (json['lat'] as num).toDouble(),
    (json['lng'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {'lat': latitude, 'lng': longitude};

  /// Great-circle distance in metres (haversine).
  double distanceTo(GeoPoint other) =>
      distanceBetween(latitude, longitude, other.latitude, other.longitude);

  /// The point [north] and [east] metres away (negative values go south and
  /// west). Accurate enough for the few-kilometre offsets used in demos.
  GeoPoint offset({double north = 0, double east = 0}) {
    final dLat = north / _earthRadiusMeters;
    final dLng =
        east / (_earthRadiusMeters * math.cos(latitude * math.pi / 180));
    return GeoPoint(
      latitude + dLat * 180 / math.pi,
      longitude + dLng * 180 / math.pi,
    );
  }

  /// Moves up to [meters] along the straight line towards [target].
  GeoPoint moveTowards(GeoPoint target, double meters) {
    final total = distanceTo(target);
    if (total <= meters || total == 0) return target;
    final t = meters / total;
    return GeoPoint(
      latitude + (target.latitude - latitude) * t,
      longitude + (target.longitude - longitude) * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() =>
      'GeoPoint(${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)})';
}

double distanceBetween(double lat1, double lng1, double lat2, double lng2) {
  double rad(double deg) => deg * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLng / 2), 2);
  return 2 * _earthRadiusMeters * math.asin(math.min(1, math.sqrt(a)));
}
