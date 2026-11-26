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

  test('delivery id round-trips and is sent to the API', () async {
    final tagged = LocationRecord(
      id: 'b',
      latitude: 1,
      longitude: 2,
      recordedAt: DateTime.utc(2026, 1, 1, 10),
      deliveryId: 'dlv_9',
    );
    await store.insert(tagged);
    final row = (await store.pendingBatch(limit: 10, now: now)).single;
    expect(row.deliveryId, 'dlv_9');
    expect(row.toApiJson()['deliveryId'], 'dlv_9');
    expect(record('c').toApiJson().containsKey('deliveryId'), isFalse);
  });

  test('a version 1 database is migrated without losing points', () async {
    final dir = Directory.systemTemp.createTempSync('geoloc_migration');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/geoloc.db';

    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute('''
          CREATE TABLE locations (
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
    await v1.insert('locations', {
      'id': 'old',
      'latitude': 1.0,
      'longitude': 2.0,
      'recorded_at': 0,
      'status': 'pending',
    });
    await v1.close();

    final migrated = await SqliteLocationStore.open(
      path: path,
      factory: databaseFactoryFfi,
    );
    addTearDown(migrated.close);
    await migrated.insert(
      LocationRecord(
        id: 'new',
        latitude: 3,
        longitude: 4,
        recordedAt: DateTime.utc(2026, 1, 1),
        deliveryId: 'dlv_1',
      ),
    );

    final rows = await migrated.pendingBatch(limit: 10, now: now);
    expect(
      {for (final r in rows) r.id: r.deliveryId},
      {'old': null, 'new': 'dlv_1'},
    );
  });
}
