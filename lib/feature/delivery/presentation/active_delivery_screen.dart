import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../application/active_delivery_controller.dart';
import '../delivery_bootstrap.dart';
import '../delivery_providers.dart';
import '../domain/delivery.dart';
import '../domain/delivery_status.dart';
import 'delivery_format.dart';
import 'verify_delivery_screen.dart';
import 'widgets/delivery_map.dart';
import 'widgets/stop_line.dart';

class ActiveDeliveryScreen extends ConsumerWidget {
  const ActiveDeliveryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(activeDeliveryProvider);
    final config = ref.watch(deliveryConfigProvider);
    final delivery = state.delivery;

    if (delivery == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: state.loading
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    state.notice == ActiveNotice.removed
                        ? "This delivery isn't assigned to you any more."
                        : 'No delivery in progress.',
                    textAlign: TextAlign.center,
                  ),
                ),
        ),
      );
    }

    final finished = delivery.status.isTerminal;
    final stop = delivery.currentStop;
    final radius = stop?.geofenceRadiusMeters ?? config.arrival.radiusMeters;

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                DeliveryMap(
                  delivery: delivery,
                  fix: state.lastFix,
                  route: state.route,
                  geofenceRadius: radius,
                  tileUrl: config.mapTileUrl,
                  attribution: config.mapAttribution,
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        IconButton.filledTonal(
                          tooltip: 'Back',
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        if (!finished && state.locationIssue != null) ...[
                          const SizedBox(height: 8),
                          _LocationIssueBanner(issue: state.locationIssue!),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          _Panel(state: state, delivery: delivery, isMock: config.isMock),
        ],
      ),
    );
  }
}

class _Panel extends ConsumerWidget {
  const _Panel({
    required this.state,
    required this.delivery,
    required this.isMock,
  });

  final ActiveDeliveryState state;
  final Delivery delivery;
  final bool isMock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final status = StatusColors.of(context);
    final controller = ref.read(activeDeliveryProvider.notifier);
    final finished = delivery.status.isTerminal;

    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      shadowColor: Colors.black26,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight:
                MediaQuery.sizeOf(context).height * (finished ? 0.9 : 0.6),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!finished) ...[
                  _Stages(status: delivery.status),
                  const SizedBox(height: 14),
                ],
                Text(stageTitle(delivery.status), style: text.headlineMedium),
                Text(
                  [
                    delivery.reference,
                    if (delivery.parcel != null) parcelLine(delivery.parcel!),
                  ].join('. '),
                  style: text.bodySmall,
                ),
                const SizedBox(height: 16),
                if (finished)
                  _Outcome(delivery: delivery)
                else
                  _Stops(state: state, delivery: delivery),
                if (state.actionError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    errorMessage(state.actionError!),
                    style: text.bodyMedium?.copyWith(color: status.failed),
                  ),
                ],
                const SizedBox(height: 16),
                _Actions(state: state, delivery: delivery),
                if (isMock && !finished) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Simulate driving'),
                    subtitle: const Text(
                      'Demo only: moves you towards the next stop.',
                    ),
                    value: state.simulateMovement,
                    onChanged: controller.setSimulateMovement,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Two-step progress: pickup, then drop-off.
class _Stages extends StatelessWidget {
  const _Stages({required this.status});

  final DeliveryStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = StatusColors.of(context).muted;
    final atDropoffStage = status.currentStop == StopKind.dropoff;

    Widget step(
      int n,
      String label, {
      required bool current,
      required bool done,
    }) {
      final color = current || done ? theme.colorScheme.primary : muted;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: current ? color : null,
              border: Border.all(color: color, width: 1.5),
            ),
            child: done
                ? Icon(Icons.check, size: 14, color: color)
                : Text(
                    '$n',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: current ? theme.colorScheme.onPrimary : color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: current ? null : muted,
              fontWeight: current ? FontWeight.w600 : null,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        step(1, 'Pickup', current: !atDropoffStage, done: atDropoffStage),
        Expanded(
          child: Container(
            height: 1.5,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            color: atDropoffStage ? theme.colorScheme.primary : muted,
          ),
        ),
        step(2, 'Drop-off', current: atDropoffStage, done: false),
      ],
    );
  }
}

class _Stops extends StatelessWidget {
  const _Stops({required this.state, required this.delivery});

  final ActiveDeliveryState state;
  final Delivery delivery;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = StatusColors.of(context);
    final stage = delivery.status;
    final atDropoffStage = stage.currentStop == StopKind.dropoff;
    final current = delivery.currentStop!;
    final distance = state.distanceToStop;

    final where = switch (stage) {
      DeliveryStatus.atPickup || DeliveryStatus.atDropoff => "You're here",
      _ when distance != null => '${formatDistance(distance)} away',
      _ => 'Waiting for your location',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StopLine(
          label: atDropoffStage ? 'Picked up' : 'Pickup, $where',
          title: delivery.pickup.name,
          subtitle: atDropoffStage ? null : delivery.pickup.address,
          filled: true,
          showConnector: true,
          dimmed: atDropoffStage,
        ),
        StopLine(
          label: atDropoffStage ? 'Drop-off, $where' : 'Drop-off',
          title: delivery.dropoff.name,
          subtitle: delivery.dropoff.address ?? delivery.dropoff.area,
          filled: false,
          dimmed: !atDropoffStage,
        ),
        if (current.instructions != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: status.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18, color: status.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(current.instructions!, style: text.bodyMedium),
                ),
              ],
            ),
          ),
        ],
        if (stage.isEnRoute) ...[
          const SizedBox(height: 10),
          Text(
            'Arrival is detected automatically within '
            '${(current.geofenceRadiusMeters ?? 75).round()} m of the stop.',
            style: text.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({required this.delivery});

  final Delivery delivery;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = StatusColors.of(context);
    final done = delivery.status == DeliveryStatus.completed;
    final at = delivery.completedAt;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          done ? Icons.check_circle : Icons.cancel_outlined,
          color: done ? status.synced : status.muted,
          size: 28,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                done
                    ? 'Handed over to ${delivery.dropoff.name}'
                          '${at == null ? '' : ' at ${formatClock(at.toLocal())}'}.'
                    : delivery.cancelReason ??
                          'Dispatch cancelled this delivery.',
                style: text.bodyLarge,
              ),
              if (done && delivery.payout != null)
                Text(
                  '${formatMoney(delivery.payout!)} added to your earnings.',
                  style: text.bodyMedium?.copyWith(color: status.muted),
                ),
              if (!done)
                Text(
                  "You don't need to do anything else for this order.",
                  style: text.bodyMedium?.copyWith(color: status.muted),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.state, required this.delivery});

  final ActiveDeliveryState state;
  final Delivery delivery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(activeDeliveryProvider.notifier);
    final busy = state.pendingAction != null;
    final big = FilledButton.styleFrom(minimumSize: const Size.fromHeight(56));
    final bigOutline = OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(56),
    );
    final stop = delivery.currentStop;

    Widget spinnerOr(String label) => busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label);

    Future<void> navigate() async {
      final target = stop?.location;
      if (target == null) return;
      final opened = await ref
          .read(navigationLauncherProvider)
          .navigateTo(target);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No maps app found to start navigation.'),
          ),
        );
      }
    }

    switch (delivery.status) {
      case DeliveryStatus.accepted || DeliveryStatus.inTransit:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: stop?.location == null ? null : navigate,
              style: big,
              icon: const Icon(Icons.navigation_outlined),
              label: const Text('Navigate'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: busy ? null : controller.markArrived,
              style: bigOutline,
              child: spinnerOr("I've arrived"),
            ),
          ],
        );
      case DeliveryStatus.atPickup:
        return FilledButton(
          onPressed: busy ? null : () => _confirmPickup(context, controller),
          style: big,
          child: spinnerOr('Confirm pickup'),
        );
      case DeliveryStatus.atDropoff:
        return FilledButton(
          onPressed: busy
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const VerifyDeliveryScreen(),
                  ),
                ),
          style: big,
          child: const Text('Enter delivery code'),
        );
      default:
        return FilledButton(
          onPressed: () {
            controller.dismiss();
            Navigator.of(context).maybePop();
          },
          style: big,
          child: const Text('Done'),
        );
    }
  }

  Future<void> _confirmPickup(
    BuildContext context,
    ActiveDeliveryController controller,
  ) async {
    final parcel = delivery.parcel;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Parcel collected?'),
        content: Text(
          parcel == null
              ? 'Confirm you have the parcel from ${delivery.pickup.name}.'
              : 'Confirm you have ${parcelLine(parcel).toLowerCase()} '
                    'from ${delivery.pickup.name}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Yes, collected'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.confirmPickup();
  }
}

class _LocationIssueBanner extends ConsumerWidget {
  const _LocationIssueBanner({required this.issue});

  final LocationIssue issue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = StatusColors.of(context);
    final controller = ref.read(activeDeliveryProvider.notifier);
    final arrival = ref.watch(activeDeliveryProvider.select((s) => s.arrival));

    final (message, action, onAction) = switch (issue) {
      LocationIssue.serviceDisabled => (
        'Location is off. Arrival detection and tracking are paused.',
        'Turn on',
        Geolocator.openLocationSettings,
      ),
      LocationIssue.permissionDenied => (
        'Location access was removed. Allow it to continue the delivery.',
        'Settings',
        Geolocator.openAppSettings,
      ),
      LocationIssue.noFix => (
        'Waiting for a GPS signal. Move to an open area if this persists.',
        'Retry',
        () async {
          controller.retryLocation();
          return true;
        },
      ),
      LocationIssue.weakSignal => (
        'Weak GPS signal'
            '${arrival?.lastAccuracyMeters == null ? '' : ' (±${arrival!.lastAccuracyMeters!.round()} m)'}'
            '. Arrival is confirmed once it improves, or tap "I\'ve arrived".',
        null,
        null,
      ),
      LocationIssue.unavailable => (
        "Couldn't read your location.",
        'Retry',
        () async {
          controller.retryLocation();
          return true;
        },
      ),
    };

    return Material(
      color: theme.colorScheme.surface,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            Icon(Icons.gps_off, size: 18, color: status.pending),
            const SizedBox(width: 10),
            Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
            if (action != null)
              TextButton(onPressed: onAction, child: Text(action)),
          ],
        ),
      ),
    );
  }
}
