import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../data/location_record.dart';
import '../providers.dart';
import '../tracking_controller.dart';

class TrackingScreen extends ConsumerWidget {
  const TrackingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keeps automatic sync alive while the screen is visible.
    ref.watch(syncCoordinatorProvider);

    final tracking = ref.watch(trackingControllerProvider);
    final snapshot = ref.watch(locationSnapshotProvider).value;
    final counts = snapshot?.counts ?? const LocationCounts();
    final recent = snapshot?.recent ?? const <LocationRecord>[];
    final online = ref.watch(isOnlineProvider).value ?? true;
    final sync = ref.watch(syncStateProvider).value;
    final controller = ref.read(trackingControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Location tracker')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(
            tracking: tracking,
            online: online,
            isSyncing: sync?.isSyncing ?? false,
            lastSyncAt: sync?.lastSyncAt,
            syncError: sync?.lastError,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _CountTile(
                label: 'Pending',
                value: counts.pending,
                icon: Icons.schedule,
              ),
              _CountTile(
                label: 'Synced',
                value: counts.synced,
                icon: Icons.cloud_done_outlined,
              ),
              _CountTile(
                label: 'Failed',
                value: counts.failed,
                icon: Icons.error_outline,
                highlight: counts.failed > 0,
              ),
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('Simulated location'),
            subtitle: const Text('Random walk instead of real GPS'),
            value: tracking.simulated,
            onChanged: tracking.isActive ? null : controller.setSimulated,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: tracking.isActive
                      ? controller.stop
                      : controller.start,
                  icon: Icon(tracking.isActive ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    tracking.isActive ? 'Stop tracking' : 'Start tracking',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: counts.pending == 0
                    ? null
                    : () => ref
                          .read(syncCoordinatorProvider)
                          .requestSync(immediate: true),
                icon: const Icon(Icons.sync),
                label: const Text('Sync now'),
              ),
            ],
          ),
          if (counts.failed > 0) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () async {
                await ref.read(locationStoreProvider).retryFailed();
                ref.read(syncCoordinatorProvider).requestSync(immediate: true);
              },
              icon: const Icon(Icons.replay),
              label: const Text('Retry failed records'),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Recent locations',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (recent.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('Nothing recorded yet')),
            )
          else
            for (final record in recent) _RecordTile(record: record),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.tracking,
    required this.online,
    required this.isSyncing,
    required this.lastSyncAt,
    required this.syncError,
  });

  final TrackingState tracking;
  final bool online;
  final bool isSyncing;
  final DateTime? lastSyncAt;
  final String? syncError;

  @override
  Widget build(BuildContext context) {
    final fix = tracking.lastFix;
    final (label, color) = switch (tracking.status) {
      TrackingStatus.tracking => ('Tracking', Colors.green),
      TrackingStatus.starting => ('Starting…', Colors.orange),
      TrackingStatus.error => ('Error', Colors.red),
      TrackingStatus.stopped => ('Stopped', Colors.grey),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Chip(
                  avatar: Icon(Icons.circle, size: 12, color: color),
                  label: Text(label),
                ),
                Chip(
                  avatar: Icon(online ? Icons.wifi : Icons.wifi_off, size: 16),
                  label: Text(online ? 'Online' : 'Offline'),
                ),
                if (isSyncing)
                  const Chip(
                    avatar: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    label: Text('Syncing'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              fix == null
                  ? 'No location yet'
                  : 'Last fix: ${fix.latitude.toStringAsFixed(5)}, '
                        '${fix.longitude.toStringAsFixed(5)}',
            ),
            if (lastSyncAt != null)
              Text('Last sync: ${_time(lastSyncAt!.toLocal())}'),
            if (tracking.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tracking.message!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (syncError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Last sync error: $syncError',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.label,
    required this.value,
    required this.icon,
    this.highlight = false,
  });

  final String label;
  final int value;
  final IconData icon;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Card(
        color: highlight ? scheme.errorContainer : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Icon(icon),
              const SizedBox(height: 4),
              Text('$value', style: Theme.of(context).textTheme.headlineSmall),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record});

  final LocationRecord record;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (record.status) {
      SyncStatus.synced => (Icons.cloud_done, Colors.green),
      SyncStatus.pending => (Icons.schedule, Colors.orange),
      SyncStatus.failed => (Icons.error, Colors.red),
    };
    final detail = StringBuffer(_time(record.recordedAt.toLocal()));
    if (record.status == SyncStatus.pending && record.attempts > 0) {
      detail.write(' · retry #${record.attempts}');
    }
    if (record.lastError != null && record.status != SyncStatus.synced) {
      detail.write(' · ${record.lastError}');
    }
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(
        '${record.latitude.toStringAsFixed(5)}, '
        '${record.longitude.toStringAsFixed(5)}',
      ),
      subtitle: Text(detail.toString()),
    );
  }
}

String _time(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
