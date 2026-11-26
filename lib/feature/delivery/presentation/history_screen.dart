import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../delivery_providers.dart';
import '../domain/delivery.dart';
import '../domain/delivery_status.dart';
import 'delivery_format.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(historyProvider);
    final controller = ref.read(historyProvider.notifier);
    final now = ref.watch(clockProvider)();
    final text = Theme.of(context).textTheme;

    Widget body;
    if (state.items.isEmpty && !state.loaded && state.error == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (state.items.isEmpty && state.error != null) {
      body = _Message(
        text: errorMessage(state.error!),
        action: 'Try again',
        onAction: controller.refresh,
      );
    } else if (state.items.isEmpty) {
      body = const _Message(
        text: 'No deliveries yet. Finished deliveries will be listed here.',
      );
    } else {
      body = ListView.separated(
        // Pull-to-refresh must work even when the list is short.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: state.items.length + 1,
        separatorBuilder: (_, i) => i < state.items.length - 1
            ? const Divider(indent: 20, endIndent: 20)
            : const SizedBox.shrink(),
        itemBuilder: (context, i) {
          if (i == state.items.length) {
            if (state.loadingMore) {
              return const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (state.error != null) {
              return _Message(
                text: "Couldn't load more deliveries.",
                action: 'Retry',
                onAction: controller.loadMore,
                inList: true,
              );
            }
            if (!state.hasMore) {
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  "That's everything.",
                  textAlign: TextAlign.center,
                  style: text.bodySmall,
                ),
              );
            }
            // The footer is built just before it scrolls into view, so
            // this also works when the first page doesn't fill the screen.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => controller.loadMore(),
            );
            return const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final d = state.items[i];
          return _HistoryRow(
            delivery: d,
            now: now,
            onTap: () => _showDetails(context, d, now),
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Delivery history')),
      body: RefreshIndicator(onRefresh: controller.refresh, child: body),
    );
  }

  void _showDetails(BuildContext context, Delivery d, DateTime now) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _Details(delivery: d, now: now),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.delivery,
    required this.now,
    required this.onTap,
  });

  final Delivery delivery;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = StatusColors.of(context);
    final done = delivery.status == DeliveryStatus.completed;
    final when = delivery.completedAt ?? delivery.acceptedAt;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${delivery.pickup.area ?? delivery.pickup.name} to '
                    '${delivery.dropoff.area ?? delivery.dropoff.name}',
                    style: text.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      delivery.reference,
                      if (when != null) formatWhen(when, now),
                    ].join(', '),
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (delivery.payout != null && done)
                  Text(formatMoney(delivery.payout!), style: text.titleMedium),
                Text(
                  statusLabel(delivery.status),
                  style: text.bodySmall?.copyWith(
                    color: done ? status.synced : status.failed,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.delivery, required this.now});

  final Delivery delivery;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final rows = <(String, String)>[
      ('Status', statusLabel(delivery.status)),
      ('Pickup', [delivery.pickup.name, ?delivery.pickup.area].join(', ')),
      ('Drop-off', [delivery.dropoff.name, ?delivery.dropoff.area].join(', ')),
      if (delivery.acceptedAt != null)
        ('Accepted', formatWhen(delivery.acceptedAt!, now)),
      if (delivery.pickedUpAt != null)
        ('Picked up', formatWhen(delivery.pickedUpAt!, now)),
      if (delivery.completedAt != null)
        ('Delivered', formatWhen(delivery.completedAt!, now)),
      if (delivery.tripDistanceMeters != null)
        ('Trip', formatDistance(delivery.tripDistanceMeters!)),
      if (delivery.parcel != null) ('Parcel', parcelLine(delivery.parcel!)),
      if (delivery.payout != null &&
          delivery.status == DeliveryStatus.completed)
        ('Earned', formatMoney(delivery.payout!)),
      if (delivery.cancelReason != null) ('Reason', delivery.cancelReason!),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(delivery.reference, style: text.headlineMedium),
            const SizedBox(height: 12),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(label, style: text.bodySmall),
                    ),
                    Expanded(child: Text(value, style: text.bodyLarge)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    this.action,
    this.onAction,
    this.inList = false,
  });

  final String text;
  final String? action;
  final VoidCallback? onAction;

  /// Shown as a list footer rather than as the whole body.
  final bool inList;

  @override
  Widget build(BuildContext context) {
    final children = [
      Text(text, textAlign: TextAlign.center),
      if (action != null) ...[
        const SizedBox(height: 12),
        Center(
          child: OutlinedButton(onPressed: onAction, child: Text(action!)),
        ),
      ],
    ];
    if (inList) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: children),
      );
    }
    // Scrollable so pull-to-refresh also works on empty and error states.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [const SizedBox(height: 80), ...children],
    );
  }
}
