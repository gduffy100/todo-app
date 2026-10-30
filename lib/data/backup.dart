import 'dart:convert';

import 'package:drift/drift.dart';

import '../domain/dependency_graph.dart';
import '../domain/ordering.dart';
import 'db.dart';

/// JSON export / import.
///
/// Import is a *merge*: rows are matched by id (link rows also by their
/// natural key) and the newer `updated_at` wins. Soft-deleted rows are
/// exported too, so deletions propagate. This is the same last-write-wins
/// rule a future cloud sync will use.
class Backup {
  Backup(this.db);
  final AppDatabase db;

  static const formatVersion = 1;

  Future<String> exportJson() async {
    Future<List<Map<String, dynamic>>> dump<T extends DataClass>(
      TableInfo<Table, T> table,
    ) async => [for (final r in await db.select(table).get()) r.toJson()];

    return const JsonEncoder.withIndent(' ').convert({
      'format': 'todo-app-backup',
      'version': formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'groups': await dump(db.taskGroups),
      'labels': await dump(db.labels),
      'tasks': await dump(db.tasks),
      'taskLabels': await dump(db.taskLabels),
      'taskDependencies': await dump(db.taskDependencies),
    });
  }

  /// Merges [json] into the database. Returns the number of rows written.
  Future<int> importJson(String json) async {
    final data = jsonDecode(json);
    if (data is! Map<String, dynamic> || data['format'] != 'todo-app-backup') {
      throw const FormatException('Not a to-do backup file');
    }
    if ((data['version'] as int? ?? 0) > formatVersion) {
      throw const FormatException('Backup is from a newer app version');
    }
    List<Map<String, dynamic>> rows(String key) =>
        ((data[key] as List?) ?? const []).cast<Map<String, dynamic>>();

    var written = 0;
    await db.transaction(() async {
      for (final g in rows('groups').map(TaskGroup.fromJson)) {
        final e = await (db.select(
          db.taskGroups,
        )..where((r) => r.id.equals(g.id))).getSingleOrNull();
        written += await _merge(db.taskGroups, g, e?.updatedAt, g.updatedAt);
      }
      for (final l in rows('labels').map(Label.fromJson)) {
        final e = await (db.select(
          db.labels,
        )..where((r) => r.id.equals(l.id))).getSingleOrNull();
        written += await _merge(db.labels, l, e?.updatedAt, l.updatedAt);
      }
      for (final t in rows('tasks').map(Task.fromJson)) {
        final e = await (db.select(
          db.tasks,
        )..where((r) => r.id.equals(t.id))).getSingleOrNull();
        written += await _merge(db.tasks, t, e?.updatedAt, t.updatedAt);
      }
      for (final tl in rows('taskLabels').map(TaskLabel.fromJson)) {
        final existing =
            await (db.select(db.taskLabels)..where(
                  (r) =>
                      r.id.equals(tl.id) |
                      (r.taskId.equals(tl.taskId) &
                          r.labelId.equals(tl.labelId)),
                ))
                .getSingleOrNull();
        written += await _merge(
          db.taskLabels,
          existing == null ? tl : tl.copyWith(id: existing.id),
          existing?.updatedAt,
          tl.updatedAt,
        );
      }
      for (final d in rows('taskDependencies').map(TaskDependency.fromJson)) {
        final existing =
            await (db.select(db.taskDependencies)..where(
                  (r) =>
                      r.id.equals(d.id) |
                      (r.taskId.equals(d.taskId) &
                          r.predecessorId.equals(d.predecessorId)),
                ))
                .getSingleOrNull();
        written += await _merge(
          db.taskDependencies,
          existing == null ? d : d.copyWith(id: existing.id),
          existing?.updatedAt,
          d.updatedAt,
        );
      }
      written += await _repair();
    });
    return written;
  }

  /// Restores invariants a merge can break:
  /// * dependency edges from two devices can form a cycle; the newest
  ///   offending edges are soft-deleted;
  /// * a live task can point at a group deleted on this device; it moves to
  ///   the end of the first live group.
  Future<int> _repair() async {
    var fixed = 0;
    final now = DateTime.now().toUtc();

    final edges =
        await (db.select(db.taskDependencies)
              ..where((d) => d.deletedAt.isNull())
              ..orderBy([(d) => OrderingTerm.asc(d.updatedAt)]))
            .get();
    final graph = <String, Set<String>>{};
    for (final e in edges) {
      if (wouldCreateCycle(graph, e.taskId, e.predecessorId)) {
        await (db.update(
          db.taskDependencies,
        )..where((d) => d.id.equals(e.id))).write(
          TaskDependenciesCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );
        fixed++;
      } else {
        graph.putIfAbsent(e.taskId, () => {}).add(e.predecessorId);
      }
    }

    final groups = await db.groupsDao.getGroups();
    if (groups.isEmpty) return fixed;
    final liveGroupIds = groups.map((g) => g.id).toSet();
    final orphans =
        await (db.select(db.tasks)
              ..where(
                (t) => t.deletedAt.isNull() & t.groupId.isNotIn(liveGroupIds),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.sortKey)]))
            .get();
    if (orphans.isEmpty) return fixed;
    final target = groups.first.id;
    final last =
        await (db.select(db.tasks)
              ..where((t) => t.groupId.equals(target) & t.deletedAt.isNull())
              ..orderBy([(t) => OrderingTerm.desc(t.sortKey)])
              ..limit(1))
            .getSingleOrNull();
    var key = last?.sortKey;
    for (final t in orphans) {
      key = keyBetween(key, null);
      await (db.update(db.tasks)..where((r) => r.id.equals(t.id))).write(
        TasksCompanion(
          groupId: Value(target),
          sortKey: Value(key),
          updatedAt: Value(now),
        ),
      );
      fixed++;
    }
    return fixed;
  }

  Future<int> _merge<T extends DataClass>(
    TableInfo<Table, T> table,
    Insertable<T> row,
    DateTime? existingUpdatedAt,
    DateTime incomingUpdatedAt,
  ) async {
    if (existingUpdatedAt != null &&
        !incomingUpdatedAt.isAfter(existingUpdatedAt)) {
      return 0;
    }
    await db.into(table).insertOnConflictUpdate(row);
    return 1;
  }
}
