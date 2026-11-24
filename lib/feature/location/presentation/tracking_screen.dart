import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../data/location_record.dart';
import '../providers.dart';
import '../services/location_source.dart';
import '../services/sync_service.dart';
import '../tracking_controller.dart';

const _tabular = [FontFeature.tabularFigures()];

class TrackingScreen extends ConsumerWidget {
  const TrackingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keeps automatic upload running while the screen is shown.
    ref.watch(syncCoordinatorProvider);

    final tracking = ref.watch(trackingControllerProvider);
    final snapshot = ref.watch(locationSnapshotProvider).value;
    final online = ref.watch(isOnlineProvider).value ?? true;
    final sync = ref.watch(syncStateProvider).value ?? const SyncState();

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            _Header(online: online),
            const SizedBox(height: 32),
            _Readout(tracking: tracking),
            const SizedBox(height: 28),
            _Controls(tracking: tracking),
            const SizedBox(height: 36),
            _UploadQueue(
              counts: snapshot?.counts ?? const LocationCounts(),
              sync: sync,
              online: online,
            ),
            const SizedBox(height: 36),
            _RecentPoints(records: snapshot?.recent ?? const []),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final status = StatusColors.of(context);
    final text = Theme.of(context).textTheme;

    return Row(
      children: [
        Text('Geoloc', style: text.titleMedium),
        const Spacer(),
        _Dot(color: online ? status.synced : status.pending),
        const SizedBox(width: 6),
        Text(online ? 'Online' : 'Offline', style: text.bodySmall),
      ],
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({required this.tracking});

  final TrackingState tracking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = StatusColors.of(context);
    final fix = tracking.lastFix;

    final (label, dotColor) = switch (tracking.status) {
      TrackingStatus.tracking => ('Recording', theme.colorScheme.primary),
      TrackingStatus.starting => ('Waiting for GPS', status.pending),
      TrackingStatus.error => ('Stopped', status.failed),
      TrackingStatus.stopped => ('Not recording', status.muted),
    };

    final coordinateStyle = theme.textTheme.headlineMedium?.copyWith(
      fontSize: 34,
      fontWeight: FontWeight.w500,
      height: 1.15,
      letterSpacing: -0.6,
      fontFeatures: _tabular,
      color: fix == null ? status.muted : null,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _Dot(
              color: dotColor,
              pulse: tracking.status == TrackingStatus.tracking,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (fix == null)
          Text('No position yet', style: coordinateStyle)
        else ...[
          Text(_latitude(fix.latitude), style: coordinateStyle),
          Text(_longitude(fix.longitude), style: coordinateStyle),
        ],
        const SizedBox(height: 10),
        if (fix != null)
          Text(_fixDetails(fix), style: theme.textTheme.bodySmall),
        if (tracking.message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tracking.message!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tracking.status == TrackingStatus.error
                    ? status.failed
                    : status.muted,
              ),
            ),
          ),
      ],
    );
  }

  static String _fixDetails(LocationFix fix) {
    final at = 'recorded at ${_clock(fix.timestamp.toLocal())}';
    final accuracy = fix.accuracy;
    if (accuracy == null) return 'Position $at';
    return 'Accurate to ${accuracy.round()} m, $at';
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({required this.tracking});

  final TrackingState tracking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(trackingControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final active = tracking.isActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('Phone GPS')),
            ButtonSegment(value: true, label: Text('Simulated')),
          ],
          selected: {tracking.simulated},
          onSelectionChanged: active
              ? null
              : (selection) => controller.setSimulated(selection.first),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: active ? controller.stop : controller.start,
          style: active
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.onSurface,
                  foregroundColor: scheme.surface,
                )
              : null,
          child: Text(active ? 'Stop recording' : 'Start recording'),
        ),
      ],
    );
  }
}

class _UploadQueue extends ConsumerWidget {
  const _UploadQueue({
    required this.counts,
    required this.sync,
    required this.online,
  });

  final LocationCounts counts;
  final SyncState sync;
  final bool online;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final status = StatusColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Upload queue', style: text.titleMedium),
        const SizedBox(height: 16),
        Row(
          children: [
            _Count(
              value: counts.pending,
              label: 'waiting',
              color: status.pending,
            ),
            _Count(
              value: counts.synced,
              label: 'uploaded',
              color: status.synced,
            ),
            _Count(
              value: counts.failed,
              label: 'rejected',
              color: status.failed,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            if (sync.isSyncing) ...[
              const SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(child: Text(_summary(), style: text.bodySmall)),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          children: [
            TextButton(
              onPressed: counts.pending == 0 || sync.isSyncing
                  ? null
                  : () => ref
                        .read(syncCoordinatorProvider)
                        .requestSync(immediate: true),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              child: const Text('Upload now'),
            ),
            if (counts.failed > 0)
              TextButton(
                onPressed: () async {
                  await ref.read(locationStoreProvider).retryFailed();
                  ref
                      .read(syncCoordinatorProvider)
                      .requestSync(immediate: true);
                },
                child: Text('Retry ${counts.failed} rejected'),
              ),
          ],
        ),
      ],
    );
  }

  String _summary() {
    if (sync.isSyncing) return 'Uploading…';
    if (counts.pending > 0 && !online) {
      return 'Offline. Waiting points upload when the connection is back.';
    }
    if (counts.pending > 0 && sync.lastError != null) {
      return 'Last upload failed (${sync.lastError}). Retrying automatically.';
    }
    final last = sync.lastSyncAt;
    if (last != null) return 'Last upload at ${_clock(last.toLocal())}';
    return counts.total == 0
        ? 'Nothing recorded yet.'
        : 'Points upload a few seconds after they are recorded.';
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.value, required this.label, required this.color});

  final int value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: text.headlineMedium?.copyWith(
              fontSize: 24,
              fontFeatures: _tabular,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              _Dot(color: color, size: 6),
              const SizedBox(width: 6),
              Text(label, style: text.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecentPoints extends StatelessWidget {
  const _RecentPoints({required this.records});

  final List<LocationRecord> records;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recent points', style: text.titleMedium),
        const SizedBox(height: 8),
        if (records.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Start recording and each point shows up here as it is saved.',
              style: text.bodySmall,
            ),
          )
        else
          for (final (i, record) in records.indexed) ...[
            if (i > 0) const Divider(),
            _PointRow(record: record),
          ],
      ],
    );
  }
}

class _PointRow extends StatelessWidget {
  const _PointRow({required this.record});

  final LocationRecord record;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = StatusColors.of(context);

    final (color, description) = switch (record.status) {
      SyncStatus.synced => (status.synced, 'Uploaded'),
      SyncStatus.failed => (
        status.failed,
        'Rejected: ${record.lastError ?? 'invalid data'}',
      ),
      SyncStatus.pending when record.attempts > 0 => (
        status.pending,
        'Waiting, ${record.attempts} failed '
            '${record.attempts == 1 ? 'attempt' : 'attempts'}',
      ),
      SyncStatus.pending => (status.pending, 'Waiting to upload'),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _Dot(color: color, size: 8),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${record.latitude.toStringAsFixed(5)}, '
                  '${record.longitude.toStringAsFixed(5)}',
                  style: text.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontFeatures: _tabular,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: text.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (record.recordedOffline) ...[
                  const SizedBox(height: 6),
                  _OfflineBadge(sent: record.status == SyncStatus.synced),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _clock(record.recordedAt.toLocal()),
            style: text.bodySmall?.copyWith(fontFeatures: _tabular),
          ),
        ],
      ),
    );
  }
}

/// Marks a point saved while the phone had no network. Grey while it waits,
/// green once the server has it.
class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge({required this.sent});

  final bool sent;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = StatusColors.of(context);
    final color = sent ? status.synced : status.muted;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          sent ? 'Offline location sent' : 'Recorded offline',
          style: text.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Status dot. With [pulse] it breathes slowly to show recording is live,
/// unless the user has asked the OS to reduce motion.
class _Dot extends StatefulWidget {
  const _Dot({required this.color, this.size = 8, this.pulse = false});

  final Color color;
  final double size;
  final bool pulse;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Dot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final animate = widget.pulse && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!animate && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = DecoratedBox(
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      child: SizedBox.square(dimension: widget.size),
    );
    if (!widget.pulse) return dot;
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.35).animate(_controller),
      child: dot,
    );
  }
}

String _latitude(double v) =>
    '${v.abs().toStringAsFixed(5)}° ${v >= 0 ? 'N' : 'S'}';

String _longitude(double v) =>
    '${v.abs().toStringAsFixed(5)}° ${v >= 0 ? 'E' : 'W'}';

String _clock(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
