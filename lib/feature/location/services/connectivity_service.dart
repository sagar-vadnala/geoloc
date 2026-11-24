import 'package:connectivity_plus/connectivity_plus.dart';

/// Thin wrapper over connectivity_plus.
///
/// "Online" only means the device has *a* network interface. It does not prove
/// the API is reachable (captive portals, server down), so a failed upload is
/// always handled by the retry/backoff logic regardless of this flag.
class ConnectivityService {
  ConnectivityService([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  Future<bool> isOnline() async =>
      _hasNetwork(await _connectivity.checkConnectivity());

  Stream<bool> get onChanged =>
      _connectivity.onConnectivityChanged.map(_hasNetwork).distinct();

  static bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);
}
