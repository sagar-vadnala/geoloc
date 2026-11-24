import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/location/data/location_record.dart';
import 'package:geoloc/feature/location/data/sqlite_location_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

LocationRecord record(String id, {int minute = 0}) => LocationRecord(
  id: id,
  latitude: 12.5,
  longitude: 77.25,
  accuracy: 8,
  recordedAt: DateTime.utc(2026, 1, 1, 10, minute),
);

void main() {
  sqfliteFfiInit();

  late SqliteLocationStore store;
  final now = DateTime.utc(2026, 1, 1, 12);

  setUp(() async {
    store = await SqliteLocationStore.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });

  tearDown(() => store.close());

  test('insert persists a record and round-trips every field', () async {
    expect(await store.insert(record('a')), isTrue);

    final rows = await store.pendingBatch(limit: 10, now: now);
    expect(rows, hasLength(1));
    expect(rows.single.id, 'a');
    expect(rows.single.latitude, 12.5);
    expect(rows.single.accuracy, 8);
    expect(rows.single.recordedAt, DateTime.utc(2026, 1, 1, 10));
    expect(rows.single.status, SyncStatus.pending);
  });

  test('inserting the same id twice stores it only once', () async {
    expect(await store.insert(record('a')), isTrue);
    expect(await store.insert(record('a')), isFalse);

    expect((await store.counts()).total, 1);
  });

  test('pendingBatch is oldest first and honours the limit', () async {
    await store.insert(record('late', minute: 30));
    await store.insert(record('early', minute: 1));
    await store.insert(record('mid', minute: 10));

    final batch = await store.pendingBatch(limit: 2, now: now);

    expect(batch.map((r) => r.id), ['early', 'mid']);
  });

  test('markSynced removes records from the pending queue for good', () async {
    await store.insert(record('a'));
    await store.insert(record('b'));

    await store.markSynced(['a'], at: now);

    expect((await store.pendingBatch(limit: 10, now: now)).map((r) => r.id), [
      'b',
    ]);
    final counts = await store.counts();
    expect(counts.pending, 1);
    expect(counts.synced, 1);
  });

  test(
    'recordFailure keeps the record pending but delays the next try',
    () async {
      await store.insert(record('a'));
      final retryAt = now.add(const Duration(seconds: 30));

      await store.recordFailure(
        ['a'],
        error: 'timeout',
        nextAttemptAt: retryAt,
      );

      expect(await store.pendingBatch(limit: 10, now: now), isEmpty);
      final due = await store.pendingBatch(limit: 10, now: retryAt);
      expect(due.single.attempts, 1);
      expect(due.single.lastError, 'timeout');
      expect(await store.earliestRetryAt(), retryAt);
    },
  );

  test('markRejected moves records out of the queue until retried', () async {
    await store.insert(record('a'));

    await store.markRejected({'a': 'bad latitude'});
    expect(await store.pendingBatch(limit: 10, now: now), isEmpty);
    expect((await store.counts()).failed, 1);

    await store.retryFailed();
    final again = await store.pendingBatch(limit: 10, now: now);
    expect(again.single.attempts, 0);
    expect(again.single.lastError, isNull);
  });

  test('watch emits an initial snapshot and a new one after changes', () async {
    final emissions = <LocationSnapshot>[];
    final sub = store.watch().listen(emissions.add);

    await pumpEventQueue();
    await store.insert(record('a'));
    await pumpEventQueue();
    await sub.cancel();

    expect(emissions.first.counts.total, 0);
    expect(emissions.last.counts.pending, 1);
    expect(emissions.last.recent.single.id, 'a');
  });

  test('remembers which points were recorded offline', () async {
    await store.insert(record('online', minute: 1));
    await store.insert(
      LocationRecord(
        id: 'offline',
        latitude: 1,
        longitude: 2,
        recordedAt: DateTime.utc(2026, 1, 1, 10, 2),
        recordedOffline: true,
      ),
    );
    await store.markSynced({'offline'}, at: now);

    final recent = (await store.watch().first).recent;
    final byId = {for (final r in recent) r.id: r};
    expect(byId['online']!.recordedOffline, isFalse);
    expect(byId['offline']!.recordedOffline, isTrue);
    expect(byId['offline']!.status, SyncStatus.synced);
  });

  test('upgrading a version 1 database keeps its points', () async {
    final dir = await Directory.systemTemp.createTemp('geoloc_store_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/geoloc.db';

    // The schema as shipped in version 1, before recorded_offline existed.
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute('''
          CREATE TABLE ${SqliteLocationStore.table} (
            id TEXT PRIMARY KEY,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            accuracy REAL,
            recorded_at INTEGER NOT NULL,
            status TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            next_attempt_at INTEGER,
            synced_at INTEGER
          )
        '''),
      ),
    );
    await v1.insert(SqliteLocationStore.table, {
      'id': 'old',
      'latitude': 1.0,
      'longitude': 2.0,
      'recorded_at': 0,
      'status': SyncStatus.pending.name,
    });
    await v1.close();

    final upgraded = await SqliteLocationStore.open(
      path: path,
      factory: databaseFactoryFfi,
    );
    addTearDown(upgraded.close);
    await upgraded.insert(
      LocationRecord(
        id: 'new',
        latitude: 1,
        longitude: 2,
        recordedAt: DateTime.utc(2026, 1, 1),
        recordedOffline: true,
      ),
    );

    final rows = await upgraded.pendingBatch(limit: 10, now: now);
    expect(
      {for (final r in rows) r.id: r.recordedOffline},
      {'old': false, 'new': true},
    );
  });
}
