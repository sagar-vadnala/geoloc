import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../providers.dart';
import '../services/location_permission_service.dart';

/// Shows [child] only once location access is granted. Until then the user
/// sees what is missing and the one action that fixes it.
class LocationGate extends ConsumerStatefulWidget {
  const LocationGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LocationGate> createState() => _LocationGateState();
}

class _LocationGateState extends ConsumerState<LocationGate> {
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<void>? _serviceSub;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(locationAccessProvider.notifier);

    // Ask on first launch instead of waiting for a tap.
    controller.refresh(askIfNeeded: true);

    // The user may change permission or the GPS toggle in Settings and come
    // back, or revoke it while the app is open.
    _lifecycle = AppLifecycleListener(onResume: controller.refresh);
    _serviceSub = ref
        .read(locationPermissionServiceProvider)
        .serviceChanges
        .listen((_) => controller.refresh(), onError: (_) {});
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _serviceSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(locationAccessProvider, (previous, next) {
      if (previous == LocationAccess.granted &&
          next != LocationAccess.granted) {
        ref.read(trackingControllerProvider.notifier).stop();
      }
    });

    final access = ref.watch(locationAccessProvider);
    return switch (access) {
      LocationAccess.granted => widget.child,
      LocationAccess.checking => const Scaffold(body: SizedBox.shrink()),
      _ => _AccessRequired(access: access),
    };
  }
}

class _AccessRequired extends ConsumerWidget {
  const _AccessRequired({required this.access});

  final LocationAccess access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(locationAccessProvider.notifier);
    final theme = Theme.of(context);
    final muted = StatusColors.of(context).muted;

    final (title, body, action, onPressed) = switch (access) {
      LocationAccess.serviceDisabled => (
        'Location is off',
        'Turn on location for this phone. Geoloc reads your position from '
            'GPS, so it can\'t record anything while it\'s switched off.',
        'Turn on location',
        controller.openSettings,
      ),
      LocationAccess.deniedForever => (
        'Location access is blocked',
        'Geoloc can\'t ask again from here. Open Settings, choose '
            'Location, and allow it while using the app.',
        'Open Settings',
        controller.openSettings,
      ),
      _ => (
        'Geoloc needs your location',
        'Every position is saved on this phone first and uploaded when '
            'you\'re online, so nothing is lost without a signal. Without '
            'location access there is nothing to record.',
        'Allow location access',
        controller.request,
      ),
    };

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              const _Reticle(),
              const SizedBox(height: 28),
              Text(title, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 12),
              Text(
                body,
                style: theme.textTheme.bodyLarge?.copyWith(color: muted),
              ),
              const Spacer(flex: 2),
              FilledButton(onPressed: onPressed, child: Text(action)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small GPS reticle drawn in code, so the gate has a mark without an asset.
class _Reticle extends StatelessWidget {
  const _Reticle();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 56,
      child: CustomPaint(
        painter: _ReticlePainter(Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  _ReticlePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(c, r * 0.62, stroke);
    canvas.drawCircle(c, r * 0.18, Paint()..color = color);
    for (final dir in const [
      Offset(1, 0),
      Offset(-1, 0),
      Offset(0, 1),
      Offset(0, -1),
    ]) {
      canvas.drawLine(c + dir * (r * 0.62), c + dir * r, stroke);
    }
  }

  @override
  bool shouldRepaint(_ReticlePainter old) => old.color != color;
}
