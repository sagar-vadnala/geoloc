import 'package:dio/dio.dart';

import '../domain/geo.dart';

class RoutePath {
  const RoutePath({
    required this.points,
    this.distanceMeters,
    this.duration,
    this.approximate = false,
  });

  final List<GeoPoint> points;
  final double? distanceMeters;
  final Duration? duration;

  /// A straight line drawn because no road route was available.
  final bool approximate;
}

abstract class RouteService {
  /// Never throws: falls back to a straight line when routing fails.
  Future<RoutePath> route(GeoPoint from, GeoPoint to);
}

/// Used when no routing server is configured.
class StraightLineRouteService implements RouteService {
  const StraightLineRouteService();

  @override
  Future<RoutePath> route(GeoPoint from, GeoPoint to) async => RoutePath(
    points: [from, to],
    distanceMeters: from.distanceTo(to),
    approximate: true,
  );
}

/// Road routes from an OSRM-compatible server (`ROUTING_URL`), e.g. a
/// self-hosted OSRM or a provider exposing the same API.
class OsrmRouteService implements RouteService {
  OsrmRouteService(
    this._dio, {
    required this.baseUrl,
    this.profile = 'driving',
  });

  final Dio _dio;
  final String baseUrl;
  final String profile;

  @override
  Future<RoutePath> route(GeoPoint from, GeoPoint to) async {
    final coords =
        '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$baseUrl/route/v1/$profile/$coords',
        queryParameters: {'overview': 'full', 'geometries': 'geojson'},
      );
      final routes = response.data?['routes'] as List?;
      if (routes == null || routes.isEmpty) {
        return await const StraightLineRouteService().route(from, to);
      }
      final best = routes.first as Map<String, dynamic>;
      final coordinates =
          (best['geometry'] as Map<String, dynamic>)['coordinates'] as List;
      return RoutePath(
        points: [
          for (final c in coordinates.cast<List<dynamic>>())
            GeoPoint((c[1] as num).toDouble(), (c[0] as num).toDouble()),
        ],
        distanceMeters: (best['distance'] as num?)?.toDouble(),
        duration: best['duration'] == null
            ? null
            : Duration(seconds: (best['duration'] as num).round()),
      );
    } catch (_) {
      return const StraightLineRouteService().route(from, to);
    }
  }
}
