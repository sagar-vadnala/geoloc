import 'package:geolocator/geolocator.dart';

/// Where the app stands with respect to being allowed to read location.
enum LocationAccess {
  checking,
  granted,

  /// Not granted yet, but the system dialog can still be shown.
  denied,

  /// The OS will not show the dialog again; only Settings can fix it.
  deniedForever,

  /// Permission is fine but location is switched off on the device.
  serviceDisabled,
}

/// Wraps the static Geolocator permission API so it can be faked in tests.
abstract class LocationPermissionService {
  Future<LocationAccess> check();
  Future<LocationAccess> request();
  Future<void> openAppSettings();
  Future<void> openLocationSettings();

  /// Emits when the device location toggle changes.
  Stream<void> get serviceChanges;
}

class GeolocatorPermissionService implements LocationPermissionService {
  @override
  Future<LocationAccess> check() async =>
      _resolve(await Geolocator.checkPermission());

  @override
  Future<LocationAccess> request() async =>
      _resolve(await Geolocator.requestPermission());

  @override
  Future<void> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  @override
  Stream<void> get serviceChanges => Geolocator.getServiceStatusStream();

  Future<LocationAccess> _resolve(LocationPermission permission) async {
    switch (permission) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return await Geolocator.isLocationServiceEnabled()
            ? LocationAccess.granted
            : LocationAccess.serviceDisabled;
      case LocationPermission.deniedForever:
        return LocationAccess.deniedForever;
      case LocationPermission.denied:
      case LocationPermission.unableToDetermine:
        return LocationAccess.denied;
    }
  }
}
