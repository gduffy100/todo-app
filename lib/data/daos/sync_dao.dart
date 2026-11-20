import 'dart:convert';

import 'package:drift/drift.dart';

import '../db.dart';

part 'sync_dao.g.dart';

/// Bookkeeping for sync: the outbox of unsent rows and small saved values.
@DriftAccessor(tables: [SyncOutbox, SyncState])
class SyncDao extends DatabaseAccessor<AppDatabase> with _$SyncDaoMixin {
  SyncDao(super.db);

  static const ownerKey = 'owner_user_id';
  static const knownListsKey = 'known_list_ids';
  static const sharedListsKey = 'shared_list_ids';
  static String cursorKey(String table) => 'cursor_$table';

  Future<String?> getValue(String key) async => (await (select(
    syncState,
  )..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setValue(String key, String value) => into(
    syncState,
  ).insertOnConflictUpdate(SyncStateCompanion.insert(key: key, value: value));

  Future<Set<String>> getIdSet(String key) async {
    final raw = await getValue(key);
    return raw == null ? {} : (jsonDecode(raw) as List).cast<String>().toSet();
  }

  Future<void> setIdSet(String key, Set<String> ids) =>
      setValue(key, jsonEncode(ids.toList()..sort()));

  /// Lists that other people can also see, as of the last sync.
  Stream<Set<String>> watchSharedListIds() =>
      (select(
        syncState,
      )..where((s) => s.key.equals(sharedListsKey))).watchSingleOrNull().map(
        (row) => row == null
            ? const <String>{}
            : (jsonDecode(row.value) as List).cast<String>().toSet(),
      );

  Future<List<SyncOutboxData>> pending(String table) =>
      (select(syncOutbox)
            ..where((o) => o.rowTable.equals(table))
            ..orderBy([(o) => OrderingTerm.asc(o.seq)]))
          .get();

  Future<int> pendingCount() async {
    final count = syncOutbox.seq.count();
    final row = await (selectOnly(syncOutbox)..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  /// Emits whenever a local change is queued, or the queue drains.
  Stream<int> watchPendingCount() {
    final count = syncOutbox.seq.count();
    return (selectOnly(
      syncOutbox,
    )..addColumns([count])).map((r) => r.read(count) ?? 0).watchSingle();
  }

  Future<bool> isPending(String table, String rowId) async =>
      await (select(syncOutbox)
            ..where((o) => o.rowTable.equals(table) & o.rowId.equals(rowId)))
          .getSingleOrNull() !=
      null;

  Future<Set<String>> pendingIds(String table) async => {
    for (final o in await pending(table)) o.rowId,
  };

  /// Clears by seq, so a row edited again while it was being sent stays queued.
  Future<void> clearSeqs(Iterable<int> seqs) =>
      (delete(syncOutbox)..where((o) => o.seq.isIn(seqs))).go();

  Future<void> clearRow(String table, String rowId) => (delete(
    syncOutbox,
  )..where((o) => o.rowTable.equals(table) & o.rowId.equals(rowId))).go();

  Future<int> maxSeq() async {
    final max = syncOutbox.seq.max();
    final row = await (selectOnly(syncOutbox)..addColumns([max])).getSingle();
    return row.read(max) ?? 0;
  }

  /// Drops everything queued after [seq]: writes that came *from* the server
  /// and so must not be sent back to it.
  Future<void> clearAfter(int seq) =>
      (delete(syncOutbox)..where((o) => o.seq.isBiggerThanValue(seq))).go();

  /// Queues every row, including soft-deleted ones, for the first upload.
  Future<void> enqueueEverything() async {
    for (final table in syncedTables) {
      await customStatement(
        'INSERT OR REPLACE INTO sync_outbox (row_table, row_id) '
        'SELECT \'$table\', id FROM $table',
      );
    }
  }
}
