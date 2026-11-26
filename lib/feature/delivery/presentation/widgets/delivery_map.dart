import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme.dart';
import '../../../location/domain/location_fix.dart';
import '../../data/route_service.dart';
import '../../domain/delivery.dart';
import '../../domain/delivery_status.dart';
import '../../domain/geo.dart';

/// Map for the active delivery: the partner's position with its accuracy
/// circle, both stops (the current one highlighted with its geofence) and
/// the route. Follows the partner until they pan, then offers a recenter.
class DeliveryMap extends StatefulWidget {
  const DeliveryMap({
    super.key,
    required this.delivery,
    required this.fix,
    required this.route,
    required this.geofenceRadius,
    required this.tileUrl,
    required this.attribution,
  });

  final Delivery delivery;
  final LocationFix? fix;
  final RoutePath? route;
  final double geofenceRadius;
  final String tileUrl;
  final String attribution;

  @override
  State<DeliveryMap> createState() => _DeliveryMapState();
}

class _DeliveryMapState extends State<DeliveryMap> {
  final _controller = MapController();
  bool _ready = false;
  bool _following = true;

  LatLng? get _me => widget.fix == null
      ? null
      : LatLng(widget.fix!.latitude, widget.fix!.longitude);

  LatLng? get _target => _ll(widget.delivery.currentStop?.location);

  @override
  void didUpdateWidget(DeliveryMap old) {
    super.didUpdateWidget(old);
    if (!_ready) return;
    final stopChanged =
        old.delivery.status.currentStop != widget.delivery.status.currentStop;
    if (stopChanged) {
      _following = true;
      _fitBoth();
    } else if (_following && _me != null && widget.fix != old.fix) {
      _controller.move(_me!, _controller.camera.zoom);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _fitBoth() {
    final points = [?_me, ?_target];
    if (points.length == 2) {
      _controller.fitCamera(
        CameraFit.coordinates(
          coordinates: points,
          padding: const EdgeInsets.fromLTRB(48, 96, 48, 48),
          maxZoom: 17,
        ),
      );
    } else if (points.length == 1) {
      _controller.move(points.single, 16);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = StatusColors.of(context);
    final primary = theme.colorScheme.primary;
    final delivery = widget.delivery;
    final current = delivery.status.currentStop;
    final me = _me;
    final target = _target;
    final route = widget.route;

    final initial =
        me ?? target ?? _ll(delivery.pickup.location) ?? const LatLng(0, 0);

    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: initial,
            initialZoom: 15,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () {
              _ready = true;
              _fitBoth();
            },
            onPositionChanged: (_, hasGesture) {
              if (hasGesture && _following) setState(() => _following = false);
            },
          ),
          children: [
            TileLayer(
              urlTemplate: widget.tileUrl,
              userAgentPackageName: 'com.example.geoloc',
            ),
            if (route != null && delivery.status.isEnRoute)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: [
                      for (final p in route.points)
                        LatLng(p.latitude, p.longitude),
                    ],
                    strokeWidth: 5,
                    color: primary.withValues(alpha: 0.8),
                    pattern: route.approximate
                        ? StrokePattern.dashed(segments: const [14, 10])
                        : const StrokePattern.solid(),
                  ),
                ],
              ),
            CircleLayer(
              circles: [
                if (target != null)
                  CircleMarker(
                    point: target,
                    radius: widget.geofenceRadius,
                    useRadiusInMeter: true,
                    color: primary.withValues(alpha: 0.10),
                    borderColor: primary.withValues(alpha: 0.5),
                    borderStrokeWidth: 1.5,
                  ),
                if (me != null && (widget.fix!.accuracy ?? 0) > 0)
                  CircleMarker(
                    point: me,
                    radius: widget.fix!.accuracy!,
                    useRadiusInMeter: true,
                    color: primary.withValues(alpha: 0.12),
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                for (final stop in [delivery.pickup, delivery.dropoff])
                  if (_ll(stop.location) case final point?)
                    Marker(
                      point: point,
                      width: 40,
                      height: 40,
                      alignment: Alignment.topCenter,
                      child: _StopPin(
                        icon: stop.kind == StopKind.pickup
                            ? Icons.storefront
                            : Icons.home_outlined,
                        color: stop.kind == current ? primary : status.muted,
                        label: stop.kind == StopKind.pickup
                            ? 'Pickup'
                            : 'Drop-off',
                      ),
                    ),
                if (me != null)
                  Marker(
                    point: me,
                    width: 22,
                    height: 22,
                    child: Semantics(
                      label: 'Your location',
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: primary,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [
                            BoxShadow(blurRadius: 4, color: Color(0x40000000)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              showFlutterMapAttribution: false,
              attributions: [
                TextSourceAttribution(
                  widget.attribution,
                  onTap: () => launchUrl(
                    Uri.parse('https://www.openstreetmap.org/copyright'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ],
            ),
          ],
        ),
        if (!_following)
          Positioned(
            right: 12,
            bottom: 12,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'Show me and the next stop',
              onPressed: () {
                setState(() => _following = true);
                _fitBoth();
              },
              child: const Icon(Icons.my_location),
            ),
          ),
      ],
    );
  }

  static LatLng? _ll(GeoPoint? p) =>
      p == null ? null : LatLng(p.latitude, p.longitude);
}

class _StopPin extends StatelessWidget {
  const _StopPin({
    required this.icon,
    required this.color,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Color(0x40000000))],
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}
