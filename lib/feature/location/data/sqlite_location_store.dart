import 'dart:async';

import 'package:sqflite/sqflite.dart';

import 'location_record.dart';
import 'location_store.dart';

class SqliteLocationStore implements LocationStore {
  SqliteLocationStore(this._db);

  static const table = 'locations';
  static const _dbVersion = 1;

  final Database _db;
  final _changes = StreamController<void>.broadcast();

  /// Opens (and migrates) the database. Tests pass `inMemoryDatabasePath`
  /// together with an ffi [factory].
  static Future<SqliteLocationStore> open({
    String? path,
    DatabaseFactory? factory,
  }) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? '${await f.getDatabasesPath()}/geoloc.db';
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE $table (
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
          ''');
          await db.execute(
            'CREATE INDEX idx_locations_status ON $table(status, recorded_at)',
          );
        },
      ),
    );
    return SqliteLocationStore(db);
  }

  @override
  Future<bool> insert(LocationRecord record) async {
    final rowId = await _db.insert(
      table,
      record.toDb(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    // sqflite returns 0 when the insert was ignored because of the PK.
    final inserted = rowId != 0;
    if (inserted) _notify();
    return inserted;
  }

  @override
  Future<List<LocationRecord>> pendingBatch({
    required int limit,
    required DateTime now,
  }) async {
    final rows = await _db.query(
      table,
      where: 'status = ? AND (next_attempt_at IS NULL OR next_attempt_at <= ?)',
      whereArgs: [SyncStatus.pending.name, now.toUtc().millisecondsSinceEpoch],
      orderBy: 'recorded_at ASC, id ASC',
      limit: limit,
    );
    return rows.map(LocationRecord.fromDb).toList();
  }

  @override
  Future<void> markSynced(Iterable<String> ids, {required DateTime at}) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _db.update(
      table,
      {
        'status': SyncStatus.synced.name,
        'synced_at': at.toUtc().millisecondsSinceEpoch,
        'last_error': null,
        'next_attempt_at': null,
      },
      where: 'id IN (${_placeholders(list.length)})',
      whereArgs: list,
    );
    _notify();
  }

  @override
  Future<void> recordFailure(
    Iterable<String> ids, {
    required String error,
    required DateTime nextAttemptAt,
  }) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _db.rawUpdate(
      'UPDATE $table SET attempts = attempts + 1, last_error = ?, '
      'next_attempt_at = ? WHERE id IN (${_placeholders(list.length)}) '
      'AND status = ?',
      [
        error,
        nextAttemptAt.toUtc().millisecondsSinceEpoch,
        ...list,
        SyncStatus.pending.name,
      ],
    );
    _notify();
  }

  @override
  Future<void> markRejected(Map<String, String> reasonById) async {
    if (reasonById.isEmpty) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      reasonById.forEach((id, reason) {
        batch.update(
          table,
          {
            'status': SyncStatus.failed.name,
            'last_error': reason,
            'next_attempt_at': null,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      });
      await batch.commit(noResult: true);
    });
    _notify();
  }

  @override
  Future<void> retryFailed() async {
    await _db.update(
      table,
      {
        'status': SyncStatus.pending.name,
        'attempts': 0,
        'last_error': null,
        'next_attempt_at': null,
      },
      where: 'status = ?',
      whereArgs: [SyncStatus.failed.name],
    );
    _notify();
  }

  @override
  Future<DateTime?> earliestRetryAt() async {
    final rows = await _db.rawQuery(
      'SELECT MIN(next_attempt_at) AS t FROM $table '
      'WHERE status = ? AND next_attempt_at IS NOT NULL',
      [SyncStatus.pending.name],
    );
    final t = rows.first['t'] as int?;
    return t == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(t, isUtc: true);
  }

  @override
  Future<LocationCounts> counts() async {
    final rows = await _db.rawQuery(
      'SELECT status, COUNT(*) AS c FROM $table GROUP BY status',
    );
    int of(SyncStatus s) => rows
        .where((r) => r['status'] == s.name)
        .map((r) => r['c'] as int)
        .fold(0, (a, b) => a + b);
    return LocationCounts(
      pending: of(SyncStatus.pending),
      synced: of(SyncStatus.synced),
      failed: of(SyncStatus.failed),
    );
  }

  @override
  Stream<LocationSnapshot> watch({int recentLimit = 20}) {
    Future<LocationSnapshot> load() async {
      final rows = await _db.query(
        table,
        orderBy: 'recorded_at DESC, id DESC',
        limit: recentLimit,
      );
      return LocationSnapshot(
        counts: await counts(),
        recent: rows.map(LocationRecord.fromDb).toList(),
      );
    }

    // One load for the initial snapshot, then one per change, in order.
    // _changes is listened to *before* the first load so a change made while
    // it runs is not missed, and cancelling the result cancels that listener.
    StreamSubscription<void>? changes;
    late final StreamController<void> triggers;
    triggers = StreamController<void>(
      onListen: () {
        changes = _changes.stream.listen(triggers.add, onDone: triggers.close);
        triggers.add(null);
      },
      onCancel: () => changes?.cancel(),
    );
    return triggers.stream.asyncMap((_) => load());
  }

  Future<void> close() async {
    await _changes.close();
    await _db.close();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static String _placeholders(int n) => List.filled(n, '?').join(',');
}
