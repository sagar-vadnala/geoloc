import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/geo.dart';

/// Hands turn-by-turn navigation to a dedicated app. Building our own
/// navigation would duplicate what Google Maps / Apple Maps already do well.
abstract class NavigationLauncher {
  /// Returns false if no app could be opened.
  Future<bool> navigateTo(GeoPoint destination);
}

class UrlNavigationLauncher implements NavigationLauncher {
  const UrlNavigationLauncher();

  @override
  Future<bool> navigateTo(GeoPoint destination) async {
    final ll = '${destination.latitude},${destination.longitude}';
    final candidates = switch (defaultTargetPlatform) {
      // Starts Google Maps navigation directly.
      TargetPlatform.android => [Uri.parse('google.navigation:q=$ll&mode=d')],
      TargetPlatform.iOS => [
        Uri.parse('comgooglemaps://?daddr=$ll&directionsmode=driving'),
        Uri.parse('https://maps.apple.com/?daddr=$ll&dirflg=d'),
      ],
      _ => <Uri>[],
    };
    for (final uri in [
      ...candidates,
      // Works everywhere: opens the Maps app if installed, else the browser.
      Uri.https('www.google.com', '/maps/dir/', {
        'api': '1',
        'destination': ll,
        'travelmode': 'driving',
      }),
    ]) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return true;
        }
      } catch (_) {
        // No handler for this scheme; try the next one.
      }
    }
    return false;
  }
}
