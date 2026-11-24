import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/core/theme.dart';
import 'package:geoloc/feature/location/data/location_record.dart';
import 'package:geoloc/feature/location/presentation/tracking_screen.dart';
import 'package:geoloc/feature/location/providers.dart';
import 'package:geoloc/feature/location/services/sync_coordinator.dart';
import 'package:geoloc/feature/location/services/sync_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class MockSyncCoordinator extends Mock implements SyncCoordinator {}

LocationRecord point(
  String id, {
  required bool offline,
  SyncStatus status = SyncStatus.pending,
}) => LocationRecord(
  id: id,
  latitude: 1,
  longitude: 2,
  recordedAt: DateTime.utc(2026),
  recordedOffline: offline,
  status: status,
);

void main() {
  testWidgets('a point recorded offline is badged, and the badge says when it '
      'has been sent', (tester) async {
    // Tall enough that the recent points list is built.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final snapshots = StreamController<LocationSnapshot>();
    addTearDown(snapshots.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncCoordinatorProvider.overrideWithValue(MockSyncCoordinator()),
          isOnlineProvider.overrideWith((ref) => Stream.value(true)),
          syncStateProvider.overrideWith(
            (ref) => Stream.value(const SyncState()),
          ),
          locationSnapshotProvider.overrideWith((ref) => snapshots.stream),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const TrackingScreen(),
        ),
      ),
    );

    snapshots.add(
      LocationSnapshot(
        counts: const LocationCounts(pending: 2),
        recent: [
          point('offline', offline: true),
          point('online', offline: false),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('Recorded offline'), findsOneWidget);
    expect(find.text('Offline location sent'), findsNothing);

    snapshots.add(
      LocationSnapshot(
        counts: const LocationCounts(synced: 2),
        recent: [
          point('offline', offline: true, status: SyncStatus.synced),
          point('online', offline: false, status: SyncStatus.synced),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('Offline location sent'), findsOneWidget);
    expect(find.text('Recorded offline'), findsNothing);
  });
}
