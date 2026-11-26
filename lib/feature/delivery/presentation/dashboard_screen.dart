import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../../location/presentation/tracking_screen.dart';
import '../../location/providers.dart';
import '../application/active_delivery_controller.dart';
import '../application/offers_controller.dart';
import '../delivery_providers.dart';
import '../domain/geo.dart';
import 'active_delivery_screen.dart';
import 'delivery_format.dart';
import 'history_screen.dart';
import 'widgets/offer_card.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Coming back to the app: catch up with anything that changed meanwhile.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        ref.read(activeDeliveryProvider.notifier).refresh();
        ref.read(offersProvider.notifier).poll();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(offersProvider.select((s) => s.notice), (_, notice) {
      if (notice == null) return;
      final message = switch (notice) {
        OffersNotice.expired => 'That request has expired.',
        OffersNotice.unavailable => 'That request is no longer available.',
        OffersNotice.acceptFailed =>
          "Couldn't accept the request. Check your connection and try again.",
      };
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
      ref.read(offersProvider.notifier).clearNotice();
    });

    final networkUp = ref.watch(isOnlineProvider).value ?? true;
    final config = ref.watch(deliveryConfigProvider);
    final active = ref.watch(activeDeliveryProvider);
    final online = ref.watch(availabilityProvider).online;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(summaryProvider);
            await Future.wait([
              ref.read(activeDeliveryProvider.notifier).refresh(),
              ref.read(offersProvider.notifier).poll(),
            ]);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              _Header(isMock: config.isMock),
              if (!networkUp) ...[
                const SizedBox(height: 12),
                const _Banner(
                  text:
                      "You're offline. Requests and updates resume when the "
                      'connection is back.',
                ),
              ],
              const SizedBox(height: 24),
              const _AvailabilityBlock(),
              if (active.delivery != null) ...[
                const SizedBox(height: 28),
                _ActiveBlock(state: active),
              ] else if (active.loading) ...[
                const SizedBox(height: 28),
                const LinearProgressIndicator(minHeight: 2),
              ] else if (active.loadError != null) ...[
                const SizedBox(height: 20),
                _InlineError(
                  text: "Couldn't check for a delivery in progress.",
                  onRetry: () =>
                      ref.read(activeDeliveryProvider.notifier).refresh(),
                ),
              ],
              if (online && !active.blocksOffers) ...[
                const SizedBox(height: 28),
                const _Requests(),
              ],
              const SizedBox(height: 32),
              const _Today(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.isMock});

  final bool isMock;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Text('Geoloc', style: text.titleMedium),
        if (isMock) ...[
          const SizedBox(width: 8),
          Text('Demo data', style: text.bodySmall),
        ],
        const Spacer(),
        IconButton(
          tooltip: 'Delivery history',
          icon: const Icon(Icons.history),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const HistoryScreen()),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (_) => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const TrackingScreen()),
          ),
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'log',
              child: Text('Location log and uploads'),
            ),
          ],
        ),
      ],
    );
  }
}

class _AvailabilityBlock extends ConsumerWidget {
  const _AvailabilityBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final status = StatusColors.of(context);
    final availability = ref.watch(availabilityProvider);
    final busy = ref.watch(activeDeliveryProvider).hasActive;
    final online = availability.online;
    final controller = ref.read(availabilityProvider.notifier);

    final subtitle = switch ((online, busy)) {
      (true, true) => 'New requests pause until this delivery is finished.',
      (true, false) => 'Requests near you appear below.',
      (false, _) => 'Go online to start receiving delivery requests.',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: online ? status.synced : status.muted,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              online ? "You're online" : "You're offline",
              style: text.headlineMedium,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: text.bodyLarge?.copyWith(color: status.muted)),
        const SizedBox(height: 16),
        if (online)
          OutlinedButton(
            onPressed: availability.updating
                ? null
                : () => controller.setOnline(false),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            child: Text(
              availability.updating ? 'Going offline…' : 'Go offline',
            ),
          )
        else
          FilledButton(
            onPressed: availability.updating
                ? null
                : () => controller.setOnline(true),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            child: Text(availability.updating ? 'Going online…' : 'Go online'),
          ),
        if (availability.error != null) ...[
          const SizedBox(height: 8),
          Text(
            errorMessage(availability.error!),
            style: text.bodyMedium?.copyWith(color: status.failed),
          ),
        ],
      ],
    );
  }
}

class _ActiveBlock extends ConsumerWidget {
  const _ActiveBlock({required this.state});

  final ActiveDeliveryState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final status = StatusColors.of(context);
    final delivery = state.delivery!;
    final stop = delivery.currentStop;
    final finished = delivery.status.isTerminal;
    final distance = state.distanceToStop;

    void open() => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ActiveDeliveryScreen()),
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border(
          left: BorderSide(
            color: finished ? status.muted : theme.colorScheme.primary,
            width: 4,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            finished ? 'Last delivery' : 'Delivery in progress',
            style: text.bodySmall,
          ),
          const SizedBox(height: 2),
          Text(stageTitle(delivery.status), style: text.titleMedium),
          if (stop != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                stop.name,
                if (distance != null) formatDistance(distance),
              ].join(', '),
              style: text.bodyLarge,
            ),
          ],
          Text(delivery.reference, style: text.bodySmall),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: finished
                ? () => ref.read(activeDeliveryProvider.notifier).dismiss()
                : open,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            child: Text(finished ? 'Done' : 'Open delivery'),
          ),
        ],
      ),
    );
  }
}

class _Requests extends ConsumerWidget {
  const _Requests();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final offers = ref.watch(offersProvider);
    final clock = ref.watch(clockProvider);
    final controller = ref.read(offersProvider.notifier);
    final fix = offers.lastFix;
    final me = fix == null ? null : GeoPoint(fix.latitude, fix.longitude);

    Widget body;
    if (offers.offers.isNotEmpty) {
      body = Column(
        children: [
          for (final view in offers.offers) ...[
            OfferCard(
              key: ValueKey(view.offer.id),
              view: view,
              now: clock,
              partnerPosition: me,
              accepting: offers.acceptingId == view.offer.id,
              otherBusy:
                  offers.acceptingId != null &&
                  offers.acceptingId != view.offer.id,
              onAccept: () async {
                final ok = await controller.accept(view.offer.id);
                if (ok && context.mounted) {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ActiveDeliveryScreen(),
                    ),
                  );
                }
              },
              onReject: () => controller.reject(view.offer.id),
            ),
            const SizedBox(height: 12),
          ],
        ],
      );
    } else if (!offers.loaded) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: LinearProgressIndicator(minHeight: 2),
      );
    } else if (offers.error != null) {
      body = _InlineError(
        text: "Couldn't load requests. Retrying automatically.",
        onRetry: controller.poll,
      );
    } else {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No requests right now. Keep the app open; new ones show up here.',
          style: text.bodyMedium,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Requests', style: text.titleMedium),
        const SizedBox(height: 12),
        body,
      ],
    );
  }
}

class _Today extends ConsumerWidget {
  const _Today();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final summary = ref.watch(summaryProvider);

    Widget figure(int value, String label) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value', style: text.headlineMedium?.copyWith(fontSize: 26)),
          Text(label, style: text.bodySmall),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Completed', style: text.titleMedium)),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const HistoryScreen()),
              ),
              child: const Text('See history'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        switch (summary) {
          AsyncData(:final value) => Row(
            children: [
              figure(value.completedToday, 'today'),
              figure(value.completedThisWeek, 'last 7 days'),
            ],
          ),
          AsyncError() => _InlineError(
            text: "Couldn't load your totals.",
            onRetry: () => ref.invalidate(summaryProvider),
          ),
          _ => const LinearProgressIndicator(minHeight: 2),
        },
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final status = StatusColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: status.pending.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off, size: 18, color: status.pending),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.text, required this.onRetry});

  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final status = StatusColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: status.failed),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}
