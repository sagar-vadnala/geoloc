import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'services/location_permission_service.dart';

/// Owns the answer to "may the app use location right now?".
///
/// The app is useless without location, so [LocationGate] keeps the tracker
/// hidden until this reports [LocationAccess.granted].
class LocationAccessController extends Notifier<LocationAccess> {
  bool _requesting = false;

  LocationPermissionService get _permissions =>
      ref.read(locationPermissionServiceProvider);

  @override
  LocationAccess build() => LocationAccess.checking;

  /// Reads the current status. With [askIfNeeded] the system dialog is shown
  /// straight away when the user hasn't answered it yet (first launch).
  Future<void> refresh({bool askIfNeeded = false}) async {
    // The permission dialog pauses and resumes the app on Android. Ignore the
    // resume-triggered refresh while our own request is still in flight.
    if (_requesting) return;

    var access = await _permissions.check();
    if (askIfNeeded && access == LocationAccess.denied) {
      access = await _request();
    }
    state = access;
  }

  Future<void> request() async {
    if (_requesting) return;
    state = await _request();
  }

  Future<LocationAccess> _request() async {
    _requesting = true;
    try {
      return await _permissions.request();
    } finally {
      _requesting = false;
    }
  }

  Future<void> openSettings() {
    return state == LocationAccess.serviceDisabled
        ? _permissions.openLocationSettings()
        : _permissions.openAppSettings();
  }
}
