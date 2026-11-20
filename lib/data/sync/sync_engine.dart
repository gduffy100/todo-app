import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../backup.dart';
import '../daos/sync_dao.dart';
import '../db.dart';
import 'cloud_backend.dart';
import 'row_codec.dart';

/// The local data belongs to a different account from the one signed in.
class AccountMismatch implements Exception {
  const AccountMismatch();
}

/// The user signed out, or changed, while a pass was running.
class SyncInterrupted implements Exception {
  const SyncInterrupted();
}

/// One sync pass: send queued local changes, fetch remote ones, then bring
/// local access in line with what the server now allows.
///
/// The server has already settled conflicts by the time a row comes back, so
/// a fetched row always replaces the local one, unless the row has an unsent
/// edit. In that case the newer `updated_at` wins.
class SyncEngine {
  SyncEngine(this.db, this.backend, {this.pageSize = 1000});

  final AppDatabase db;
  final CloudBackend backend;

  /// Rows per request. Must not exceed the server's own cap (1000 on
  /// Supabase), because a short page is taken to mean there are no more.
  final int pageSize;

  static const _pushChunk = 200;

  /// Ids per `in (...)` filter, which goes in the URL.
  static const _inChunk = 100;

  /// Re-reads recent rows on each pass. `now()` on the server is the time a
  /// transaction started, so a slow one can commit behind the cursor.
  static const _cursorOverlap = Duration(seconds: 60);

  SyncDao get _dao => db.syncDao;

  /// Runs one pass for [userId]. Throws [AccountMismatch] instead of mixing
  /// this device's data into a second account, and [SyncInterrupted] if the
  /// user signs out part way through.
  Future<void> sync(String userId) async {
    await _claim(userId);
    await _adoptSeedRows(userId);
    await _push(userId);
    await _pull();
    await _reconcileAccess(userId);
    await Backup(db).repair();
    // Send repairs, and rows held back for a parent, now rather than later.
    if (await _dao.pendingCount() > 0) await _push(userId);
  }

  void _checkUser(String userId) {
    if (backend.currentUser?.id != userId) throw const SyncInterrupted();
  }

  // ------------------------------------------------------------ first sync

  Future<void> _claim(String userId) async {
    final owner = await _dao.getValue(SyncDao.ownerKey);
    if (owner == userId) return;
    if (owner != null) throw const AccountMismatch();
    await db.transaction(() async {
      await _dao.setValue(SyncDao.ownerKey, userId);
      await _dao.enqueueEverything();
    });
  }

  /// Seed rows have the same id on every install, which lets one person's
  /// devices merge them but would collide between people in the cloud. Each
  /// is given an id derived from the user, which is still the same on all of
  /// that user's devices. Later imports of old backups can bring seed ids
  /// back, so this runs on every pass.
  ///
  /// The rows this changes are queued by the outbox triggers. Nothing else is
  /// re-queued: that would re-send other people's rows and local evictions.
  ///
  /// The hard deletes below remove local duplicates that were never synced,
  /// after moving everything that pointed at them.
  Future<void> _adoptSeedRows(String userId) async {
    final seedGroups = await (db.select(
      db.taskGroups,
    )..where((g) => g.id.like('seed-%'))).get();
    final seedLabels = await (db.select(
      db.labels,
    )..where((l) => l.id.like('seed-%'))).get();
    if (seedGroups.isEmpty && seedLabels.isEmpty) return;

    String adopted(String id) => const Uuid().v5(userId, id);
    await db.transaction(() async {
      await db.customStatement('PRAGMA defer_foreign_keys = ON');
      for (final g in seedGroups) {
        final id = adopted(g.id);
        final exists = await (db.select(
          db.taskGroups,
        )..where((r) => r.id.equals(id))).getSingleOrNull();
        await db.customUpdate(
          'UPDATE tasks SET group_id = ? WHERE group_id = ?',
          variables: [Variable(id), Variable(g.id)],
          updates: {db.tasks},
        );
        if (exists == null) {
          await db.customUpdate(
            'UPDATE task_groups SET id = ?, owner_id = ? WHERE id = ?',
            variables: [Variable(id), Variable(userId), Variable(g.id)],
            updates: {db.taskGroups},
          );
        } else {
          await (db.delete(
            db.taskGroups,
          )..where((r) => r.id.equals(g.id))).go();
        }
      }
      for (final l in seedLabels) {
        final id = adopted(l.id);
        final exists = await (db.select(
          db.labels,
        )..where((r) => r.id.equals(id))).getSingleOrNull();
        await db.customUpdate(
          'UPDATE OR IGNORE task_labels SET label_id = ? WHERE label_id = ?',
          variables: [Variable(id), Variable(l.id)],
          updates: {db.taskLabels},
        );
        await (db.delete(
          db.taskLabels,
        )..where((r) => r.labelId.equals(l.id))).go();
        if (exists == null) {
          await db.customUpdate(
            'UPDATE labels SET id = ?, owner_id = ? WHERE id = ?',
            variables: [Variable(id), Variable(userId), Variable(l.id)],
            updates: {db.labels},
          );
        } else {
          await (db.delete(db.labels)..where((r) => r.id.equals(l.id))).go();
        }
      }
      await db.customStatement(
        "DELETE FROM sync_outbox WHERE row_id LIKE 'seed-%'",
      );
    });
  }

  // ------------------------------------------------------------------ push

  Future<void> _push(String userId) async {
    await _pushTable(userId, 'task_groups', 'id', (ids) async {
      final rows = await (db.select(
        db.taskGroups,
      )..where((r) => r.id.isIn(ids))).get();
      return {for (final r in rows) r.id: encodeGroup(r)};
    });
    await _pushTable(userId, 'labels', 'id', (ids) async {
      final rows = await (db.select(
        db.labels,
      )..where((r) => r.id.isIn(ids))).get();
      return {for (final r in rows) r.id: encodeLabel(r)};
    });
    await _pushTable(userId, 'tasks', 'id', (ids) async {
      final rows = await (db.select(
        db.tasks,
      )..where((r) => r.id.isIn(ids))).get();
      return {for (final r in rows) r.id: encodeTask(r)};
    });
    await _pushTable(userId, 'task_labels', 'task_id,label_id', (ids) async {
      final rows = await (db.select(
        db.taskLabels,
      )..where((r) => r.id.isIn(ids))).get();
      return {for (final r in rows) r.id: encodeTaskLabel(r)};
    });
    await _pushTable(userId, 'task_dependencies', 'task_id,predecessor_id', (
      ids,
    ) async {
      final rows = await (db.select(
        db.taskDependencies,
      )..where((r) => r.id.isIn(ids))).get();
      return {for (final r in rows) r.id: encodeDependency(r)};
    });
  }

  Future<void> _pushTable(
    String userId,
    String table,
    String onConflict,
    Future<Map<String, Map<String, dynamic>>> Function(List<String> ids) load,
  ) async {
    final pending = await _dao.pending(table);
    for (var i = 0; i < pending.length; i += _pushChunk) {
      final chunk = pending.sublist(
        i,
        (i + _pushChunk).clamp(0, pending.length),
      );
      final rows = await load([for (final o in chunk) o.rowId]);
      final present = [
        for (final o in chunk)
          if (rows.containsKey(o.rowId)) o,
      ];
      final stored = <String>{};
      final held = <int>{};
      try {
        if (present.isNotEmpty) {
          stored.addAll(
            await backend.upsert(table, [
              for (final o in present) rows[o.rowId]!,
            ], onConflict: onConflict),
          );
        }
      } on RowsRejected {
        // One bad row must not hold up the rest, so retry them singly.
        for (final o in present) {
          try {
            stored.addAll(
              await backend.upsert(table, [
                rows[o.rowId]!,
              ], onConflict: onConflict),
            );
          } on RowsRejected {
            // A parent created after its table was sent is not on the server
            // yet, so the child looks unreachable. Keep it for the next push.
            // Anything else was refused because access was lost; the access
            // check after the pull corrects the local copy.
            if (await _parentQueued(table, rows[o.rowId]!)) held.add(o.seq);
          }
        }
      }
      // Never clear the outbox for a pass that is no longer this user's.
      _checkUser(userId);
      await _dao.clearSeqs([
        for (final o in chunk)
          if (!held.contains(o.seq)) o.seq,
      ]);
      // Rows the server kept its newer copy of: show that copy here too,
      // since its stamp may already be behind this device's cursor.
      final lost = [
        for (final o in present)
          if (!stored.contains(o.rowId) && !held.contains(o.seq)) o.rowId,
      ];
      if (lost.isNotEmpty) {
        await _apply(table, await _whereIn(table, 'id', lost));
      }
    }
  }

  Future<bool> _parentQueued(String table, Map<String, dynamic> row) async =>
      switch (table) {
        'tasks' => await _dao.isPending(
          'task_groups',
          row['group_id'] as String,
        ),
        'task_labels' =>
          await _dao.isPending('tasks', row['task_id'] as String) ||
              await _dao.isPending('labels', row['label_id'] as String),
        'task_dependencies' =>
          await _dao.isPending('tasks', row['task_id'] as String) ||
              await _dao.isPending('tasks', row['predecessor_id'] as String),
        _ => false,
      };

  // ------------------------------------------------------------------ pull

  /// Pages by (stamp, id) rather than offset: a row updated mid-pull moves to
  /// the end, which would shift an offset and skip a row for good.
  Future<void> _pull() async {
    for (final table in syncedTables) {
      final key = SyncDao.cursorKey(table);
      final saved = await _dao.getValue(key);
      final since = saved == null
          ? null
          : DateTime.parse(saved).subtract(_cursorOverlap);
      DateTime? newest = saved == null ? null : DateTime.parse(saved);
      PagePosition? after;
      while (true) {
        final page = await backend.fetchChanged(
          table,
          since: since,
          after: after,
          limit: pageSize,
        );
        await _apply(table, page);
        for (final r in page) {
          final at = DateTime.parse(r['server_updated_at'] as String);
          if (newest == null || at.isAfter(newest)) newest = at;
        }
        if (page.length < pageSize) break;
        after = PagePosition(
          page.last['server_updated_at'] as String,
          page.last['id'] as String,
        );
      }
      if (newest != null) {
        await _dao.setValue(key, newest.toUtc().toIso8601String());
      }
    }
  }

  /// Every row of [table] whose [column] is in [values], across all pages.
  Future<List<Map<String, dynamic>>> _whereIn(
    String table,
    String column,
    List<String> values,
  ) async {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < values.length; i += _inChunk) {
      final chunk = values.sublist(i, (i + _inChunk).clamp(0, values.length));
      String? afterId;
      while (true) {
        final page = await backend.fetchWhereIn(
          table,
          column,
          chunk,
          afterId: afterId,
          limit: pageSize,
        );
        out.addAll(page);
        if (page.length < pageSize) break;
        afterId = page.last['id'] as String;
      }
    }
    return out;
  }

  /// Applies server rows, first fetching any parents not held locally. A label
  /// or task can become visible long after its own stamp has been passed.
  Future<void> _apply(String table, List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    switch (table) {
      case 'tasks':
        await _fetchMissing('task_groups', db.taskGroups, {
          for (final r in rows) r['group_id'] as String,
        });
      case 'task_labels':
        await _fetchMissing('tasks', db.tasks, {
          for (final r in rows) r['task_id'] as String,
        });
        await _fetchMissing('labels', db.labels, {
          for (final r in rows) r['label_id'] as String,
        });
      case 'task_dependencies':
        await _fetchMissing('tasks', db.tasks, {
          for (final r in rows) ...[
            r['task_id'] as String,
            r['predecessor_id'] as String,
          ],
        });
    }
    await db.transaction(() async {
      final before = await _dao.maxSeq();
      for (final r in rows) {
        switch (table) {
          case 'task_groups':
            await _applyGroup(decodeGroup(r));
          case 'labels':
            await _applyLabel(decodeLabel(r));
          case 'tasks':
            await _applyTask(decodeTask(r));
          case 'task_labels':
            await _applyTaskLabel(decodeTaskLabel(r));
          case 'task_dependencies':
            await _applyDependency(decodeDependency(r));
        }
      }
      await _dao.clearAfter(before);
    });
  }

  Future<void> _fetchMissing<T extends Table, R>(
    String table,
    TableInfo<T, R> info,
    Set<String> ids,
  ) async {
    final idColumn = info.columnsByName['id']! as Expression<String>;
    final query = db.selectOnly(info)
      ..addColumns([idColumn])
      ..where(idColumn.isIn(ids));
    final held = {for (final row in await query.get()) row.read(idColumn)!};
    final missing = ids.difference(held).toList();
    if (missing.isEmpty) return;
    await _apply(table, await _whereIn(table, 'id', missing));
  }

  // Rows are written with toCompanion(false) throughout: a bare data class
  // leaves nulls out of the update, so a cleared due date, an un-completed
  // task or a restored row would never overwrite the old value.

  /// True if the incoming row should replace what is held locally. A row that
  /// loses here stays queued, and the server will settle it on the next push.
  Future<bool> _accepts(
    String table,
    String id,
    DateTime? localUpdatedAt,
    DateTime incomingUpdatedAt,
  ) async {
    if (localUpdatedAt == null || !await _dao.isPending(table, id)) return true;
    if (!incomingUpdatedAt.isAfter(localUpdatedAt)) return false;
    await _dao.clearRow(table, id);
    return true;
  }

  Future<void> _applyGroup(TaskGroup g) async {
    final local = await (db.select(
      db.taskGroups,
    )..where((r) => r.id.equals(g.id))).getSingleOrNull();
    if (local != null && _same(encodeGroup(local), encodeGroup(g))) {
      if (local.ownerId == g.ownerId) return;
    }
    if (!await _accepts('task_groups', g.id, local?.updatedAt, g.updatedAt)) {
      return;
    }
    await db.into(db.taskGroups).insertOnConflictUpdate(g.toCompanion(false));
  }

  Future<void> _applyLabel(Label l) async {
    final local = await (db.select(
      db.labels,
    )..where((r) => r.id.equals(l.id))).getSingleOrNull();
    if (local != null && _same(encodeLabel(local), encodeLabel(l))) {
      if (local.ownerId == l.ownerId) return;
    }
    if (!await _accepts('labels', l.id, local?.updatedAt, l.updatedAt)) return;
    await db.into(db.labels).insertOnConflictUpdate(l.toCompanion(false));
  }

  Future<void> _applyTask(Task t) async {
    if (!await _held(db.taskGroups, t.groupId)) return;
    final local = await (db.select(
      db.tasks,
    )..where((r) => r.id.equals(t.id))).getSingleOrNull();
    if (local != null && _same(encodeTask(local), encodeTask(t))) return;
    if (!await _accepts('tasks', t.id, local?.updatedAt, t.updatedAt)) return;
    await db.into(db.tasks).insertOnConflictUpdate(t.toCompanion(false));
  }

  /// Two devices can create the same link under different ids. The server
  /// keeps one row per link, so the local row takes on the server's id; the
  /// local duplicate is replaced, not soft-deleted, as it was never synced
  /// under its own id.
  Future<void> _applyTaskLabel(TaskLabel l) async {
    if (!await _held(db.tasks, l.taskId) ||
        !await _held(db.labels, l.labelId)) {
      return;
    }
    final local =
        await (db.select(db.taskLabels)..where(
              (r) => r.taskId.equals(l.taskId) & r.labelId.equals(l.labelId),
            ))
            .getSingleOrNull();
    if (local != null && _same(encodeTaskLabel(local), encodeTaskLabel(l))) {
      return;
    }
    if (!await _accepts(
      'task_labels',
      local?.id ?? l.id,
      local?.updatedAt,
      l.updatedAt,
    )) {
      return;
    }
    if (local != null && local.id != l.id) {
      await (db.delete(
        db.taskLabels,
      )..where((r) => r.id.equals(local.id))).go();
    }
    await db.into(db.taskLabels).insertOnConflictUpdate(l.toCompanion(false));
  }

  Future<void> _applyDependency(TaskDependency d) async {
    if (!await _held(db.tasks, d.taskId) ||
        !await _held(db.tasks, d.predecessorId)) {
      return;
    }
    final local =
        await (db.select(db.taskDependencies)..where(
              (r) =>
                  r.taskId.equals(d.taskId) &
                  r.predecessorId.equals(d.predecessorId),
            ))
            .getSingleOrNull();
    if (local != null && _same(encodeDependency(local), encodeDependency(d))) {
      return;
    }
    if (!await _accepts(
      'task_dependencies',
      local?.id ?? d.id,
      local?.updatedAt,
      d.updatedAt,
    )) {
      return;
    }
    if (local != null && local.id != d.id) {
      await (db.delete(
        db.taskDependencies,
      )..where((r) => r.id.equals(local.id))).go();
    }
    await db
        .into(db.taskDependencies)
        .insertOnConflictUpdate(d.toCompanion(false));
  }

  Future<bool> _held<T extends Table, R>(
    TableInfo<T, R> info,
    String id,
  ) async {
    final idColumn = info.columnsByName['id']! as Expression<String>;
    final query = db.selectOnly(info)
      ..addColumns([idColumn])
      ..where(idColumn.equals(id));
    return await query.getSingleOrNull() != null;
  }

  bool _same(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- access

  /// A cursor only finds rows that changed, so it cannot notice access being
  /// gained or lost. This compares the lists and tasks this user can reach
  /// with what is held locally.
  Future<void> _reconcileAccess(String userId) async {
    final lists = <AccessibleList>[];
    String? afterId;
    while (true) {
      final page = await backend.accessibleLists(
        afterId: afterId,
        limit: pageSize,
      );
      lists.addAll(page);
      if (page.length < pageSize) break;
      afterId = page.last.id;
    }
    final reachable = {for (final l in lists) l.id};
    final shared = {
      for (final l in lists)
        if (l.isShared) l.id,
    };
    final known = await _dao.getIdSet(SyncDao.knownListsKey);
    final firstPass = known.isEmpty;

    if (!firstPass) await _backfill(reachable.difference(known).toList());
    await _evictLists(known.difference(reachable));
    await _evictMovedTasks(shared.toList());

    await _dao.setIdSet(SyncDao.knownListsKey, reachable);
    await _dao.setIdSet(SyncDao.sharedListsKey, shared);
  }

  /// Joining a list exposes rows older than this device's cursor, so they are
  /// fetched explicitly, in dependency order. Dependencies are fetched from
  /// both ends: an edge from a list already held to one just joined was
  /// hidden until now too.
  Future<void> _backfill(List<String> listIds) async {
    if (listIds.isEmpty) return;
    await _apply('task_groups', await _whereIn('task_groups', 'id', listIds));
    final tasks = await _whereIn('tasks', 'group_id', listIds);
    await _apply('tasks', tasks);
    final taskIds = [for (final t in tasks) t['id'] as String];
    await _apply(
      'task_labels',
      await _whereIn('task_labels', 'task_id', taskIds),
    );
    await _apply(
      'task_dependencies',
      await _whereIn('task_dependencies', 'task_id', taskIds),
    );
    await _apply(
      'task_dependencies',
      await _whereIn('task_dependencies', 'predecessor_id', taskIds),
    );
  }

  /// Hides lists this user was removed from. The rows are soft-deleted with
  /// `updated_at` untouched and are not queued: this is a local view of access,
  /// not an edit, and must never reach the people still on the list. Rejoining
  /// restores them, because a fetched row replaces one with no unsent edit.
  Future<void> _evictLists(Set<String> listIds) async {
    if (listIds.isEmpty) return;
    final tasks = await (db.select(
      db.tasks,
    )..where((t) => t.groupId.isIn(listIds))).get();
    await db.transaction(() async {
      final now = nowUtc();
      final before = await _dao.maxSeq();
      await (db.update(db.taskGroups)..where((g) => g.id.isIn(listIds))).write(
        TaskGroupsCompanion(deletedAt: Value(now)),
      );
      await _softDeleteTasks([for (final t in tasks) t.id], now);
      await _dao.clearAfter(before);
    });
  }

  /// Someone can move a task out of a shared list to a list others cannot
  /// see. That row simply stops being returned, so it has to be detected.
  Future<void> _evictMovedTasks(List<String> sharedListIds) async {
    if (sharedListIds.isEmpty) return;
    final onServer = <String>{};
    for (var i = 0; i < sharedListIds.length; i += _inChunk) {
      final chunk = sharedListIds.sublist(
        i,
        (i + _inChunk).clamp(0, sharedListIds.length),
      );
      String? afterId;
      while (true) {
        final page = await backend.taskIdsInLists(
          chunk,
          afterId: afterId,
          limit: pageSize,
        );
        onServer.addAll(page);
        if (page.length < pageSize) break;
        afterId = page.last;
      }
    }
    final local =
        await (db.select(db.tasks)..where(
              (t) => t.groupId.isIn(sharedListIds) & t.deletedAt.isNull(),
            ))
            .get();
    final unsent = await _dao.pendingIds('tasks');
    final gone = [
      for (final t in local)
        if (!onServer.contains(t.id) && !unsent.contains(t.id)) t.id,
    ];
    if (gone.isEmpty) return;
    await db.transaction(() async {
      final before = await _dao.maxSeq();
      await _softDeleteTasks(gone, nowUtc());
      await _dao.clearAfter(before);
    });
  }

  Future<void> _softDeleteTasks(List<String> ids, DateTime now) async {
    if (ids.isEmpty) return;
    await (db.update(db.tasks)..where((t) => t.id.isIn(ids))).write(
      TasksCompanion(deletedAt: Value(now)),
    );
    await (db.update(db.taskLabels)..where((l) => l.taskId.isIn(ids))).write(
      TaskLabelsCompanion(deletedAt: Value(now)),
    );
    await (db.update(db.taskDependencies)
          ..where((d) => d.taskId.isIn(ids) | d.predecessorId.isIn(ids)))
        .write(TaskDependenciesCompanion(deletedAt: Value(now)));
  }
}
