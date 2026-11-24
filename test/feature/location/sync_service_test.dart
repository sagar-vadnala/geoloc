import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/location/data/location_api.dart';
import 'package:geoloc/feature/location/data/location_record.dart';
import 'package:geoloc/feature/location/data/sqlite_location_store.dart';
import 'package:geoloc/feature/location/services/sync_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockLocationApi extends Mock implements LocationApi {}

LocationRecord record(String id, {int minute = 0}) => LocationRecord(
  id: id,
  latitude: 10,
  longitude: 20,
  recordedAt: DateTime.utc(2026, 1, 1, 10, minute),
);

void main() {
  sqfliteFfiInit();
  setUpAll(() => registerFallbackValue(<LocationRecord>[]));

  late SqliteLocationStore store;
  late MockLocationApi api;
  late DateTime clock;
  late bool online;

  SyncService buildService({int batchSize = 50}) => SyncService(
    store: store,
    api: api,
    isOnline: () async => online,
    now: () => clock,
    batchSize: batchSize,
    backoff: (attempts) => const Duration(seconds: 10),
  );

  List<String> idsOf(Invocation call) =>
      (call.positionalArguments.first as List<LocationRecord>)
          .map((r) => r.id)
          .toList();

  setUp(() async {
    store = await SqliteLocationStore.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    api = MockLocationApi();
    clock = DateTime.utc(2026, 1, 1, 12);
    online = true;
  });

  tearDown(() => store.close());

  test('uploads pending records and marks them synced', () async {
    await store.insert(record('a', minute: 1));
    await store.insert(record('b', minute: 2));
    when(() => api.uploadBatch(any()))
        .thenAnswer((_) async => const UploadResult(accepted: {'a', 'b'}));

    final outcome = await buildService().sync();

    expect(outcome, SyncOutcome.completed);
    final counts = await store.counts();
    expect(counts.synced, 2);
    expect(counts.pending, 0);
  });

  test('records already known to the server count as synced', () async {
    await store.insert(record('a'));
    when(() => api.uploadBatch(any()))
        .thenAnswer((_) async => const UploadResult(duplicates: {'a'}));

    await buildService().sync();

    expect((await store.counts()).synced, 1);
  });

  test('network failure keeps data, backs off, then succeeds without '
      'duplicating', () async {
    await store.insert(record('a'));
    final service = buildService();

    when(() => api.uploadBatch(any()))
        .thenThrow(const ApiException('timeout', retryable: true));
    expect(await service.sync(), SyncOutcome.failed);

    var counts = await store.counts();
    expect(counts.pending, 1);
    expect(counts.synced, 0);

    // Still inside the backoff window: the API must not be called again.
    clearInteractions(api);
    await service.sync();
    verifyNever(() => api.uploadBatch(any()));

    // Backoff elapsed and the server is back.
    clock = clock.add(const Duration(seconds: 11));
    when(() => api.uploadBatch(any()))
        .thenAnswer((_) async => const UploadResult(accepted: {'a'}));
    expect(await service.sync(), SyncOutcome.completed);
    counts = await store.counts();
    expect(counts.synced, 1);
    expect(counts.pending, 0);

    // Nothing left to send: a further sync must not re-upload 'a'.
    clearInteractions(api);
    await service.sync();
    verifyNever(() => api.uploadBatch(any()));
  });

  test('records the attempt count and error message on failure', () async {
    await store.insert(record('a'));
    when(() => api.uploadBatch(any()))
        .thenThrow(const ApiException('Server responded 503', retryable: true));

    await buildService().sync();

    clock = clock.add(const Duration(seconds: 11));
    final due = await store.pendingBatch(limit: 10, now: clock);
    expect(due.single.attempts, 1);
    expect(due.single.lastError, 'Server responded 503');
  });

  test(
    'records rejected by the server become failed, others still sync',
    () async {
      await store.insert(record('good', minute: 1));
      await store.insert(record('bad', minute: 2));
      when(() => api.uploadBatch(any())).thenAnswer(
        (_) async => const UploadResult(
          accepted: {'good'},
          rejected: {'bad': 'latitude out of range'},
        ),
      );

      final outcome = await buildService().sync();

      expect(outcome, SyncOutcome.completed);
      final counts = await store.counts();
      expect(counts.synced, 1);
      expect(counts.failed, 1);
      expect(counts.pending, 0);
    },
  );

  test(
    'a non-retryable error marks the batch failed instead of looping',
    () async {
      await store.insert(record('a'));
      when(
        () => api.uploadBatch(any()),
      ).thenThrow(const ApiException('Server responded 422', retryable: false));

      await buildService().sync();

      expect((await store.counts()).failed, 1);
      verify(() => api.uploadBatch(any())).called(1);
    },
  );

  test('ids the server did not acknowledge stay pending', () async {
    await store.insert(record('a', minute: 1));
    await store.insert(record('b', minute: 2));
    when(() => api.uploadBatch(any()))
        .thenAnswer((_) async => const UploadResult(accepted: {'a'}));

    final outcome = await buildService().sync();

    expect(outcome, SyncOutcome.failed);
    final counts = await store.counts();
    expect(counts.synced, 1);
    expect(counts.pending, 1);
  });

  test('does nothing while offline', () async {
    await store.insert(record('a'));
    online = false;

    final outcome = await buildService().sync();

    expect(outcome, SyncOutcome.offline);
    verifyNever(() => api.uploadBatch(any()));
    expect((await store.counts()).pending, 1);
  });

  test('overlapping sync calls upload each record only once', () async {
    await store.insert(record('a'));
    final gate = Completer<UploadResult>();
    when(() => api.uploadBatch(any())).thenAnswer((_) => gate.future);
    final service = buildService();

    final first = service.sync();
    await pumpEventQueue();
    final second = await service.sync();
    gate.complete(const UploadResult(accepted: {'a'}));

    expect(second, SyncOutcome.alreadyRunning);
    expect(await first, SyncOutcome.completed);
    verify(() => api.uploadBatch(any())).called(1);
  });

  test('uploads in batches of the configured size, oldest first', () async {
    for (var i = 0; i < 5; i++) {
      await store.insert(record('r$i', minute: i));
    }
    final batches = <List<String>>[];
    when(() => api.uploadBatch(any())).thenAnswer((call) async {
      final ids = idsOf(call);
      batches.add(ids);
      return UploadResult(accepted: ids.toSet());
    });

    await buildService(batchSize: 2).sync();

    expect(batches, [
      ['r0', 'r1'],
      ['r2', 'r3'],
      ['r4'],
    ]);
    expect((await store.counts()).synced, 5);
  });
}
