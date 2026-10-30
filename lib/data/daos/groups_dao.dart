import 'package:drift/drift.dart';

import '../../domain/ordering.dart';
import '../db.dart';

part 'groups_dao.g.dart';

@DriftAccessor(tables: [TaskGroups, Tasks])
class GroupsDao extends DatabaseAccessor<AppDatabase> with _$GroupsDaoMixin {
  GroupsDao(super.db);

  SimpleSelectStatement<$TaskGroupsTable, TaskGroup> _live() =>
      select(taskGroups)
        ..where((g) => g.deletedAt.isNull())
        ..orderBy([
          (g) => OrderingTerm.asc(g.sortKey),
          (g) => OrderingTerm.asc(g.id),
        ]);

  Stream<List<TaskGroup>> watchGroups() => _live().watch();
  Future<List<TaskGroup>> getGroups() => _live().get();

  Future<String> createGroup(String name) async {
    final groups = await getGroups();
    final key = keyBetween(groups.isEmpty ? null : groups.last.sortKey, null);
    final row = await into(taskGroups).insertReturning(
      TaskGroupsCompanion.insert(name: name.trim(), sortKey: key),
    );
    return row.id;
  }

  Future<void> renameGroup(String id, String name) =>
      (update(taskGroups)..where((g) => g.id.equals(id))).write(
        TaskGroupsCompanion(
          name: Value(name.trim()),
          updatedAt: Value(nowUtc()),
        ),
      );

  /// Moves group [id] so it ends up at [newIndex] in the ordered list.
  Future<void> reorderGroup(String id, int newIndex) async {
    final others = (await getGroups()).where((g) => g.id != id).toList();
    final key = keyAtIndex([for (final g in others) g.sortKey], newIndex);
    await (update(taskGroups)..where((g) => g.id.equals(id))).write(
      TaskGroupsCompanion(sortKey: Value(key), updatedAt: Value(nowUtc())),
    );
  }

  /// Soft-deletes a user group. Its tasks move to the end of the first
  /// remaining group. System groups cannot be deleted.
  Future<void> deleteGroup(String id) => transaction(() async {
    final groups = await getGroups();
    final group = groups.firstWhere((g) => g.id == id);
    if (group.isSystem) {
      throw StateError('System group "${group.name}" cannot be deleted');
    }
    final target = groups.firstWhere((g) => g.id != id);
    final now = nowUtc();
    final moving =
        await (select(tasks)
              ..where((t) => t.groupId.equals(id) & t.deletedAt.isNull())
              ..orderBy([(t) => OrderingTerm.asc(t.sortKey)]))
            .get();
    final last =
        await (select(tasks)
              ..where((t) => t.groupId.equals(target.id) & t.deletedAt.isNull())
              ..orderBy([(t) => OrderingTerm.desc(t.sortKey)])
              ..limit(1))
            .getSingleOrNull();
    var prev = last?.sortKey;
    for (final t in moving) {
      prev = keyBetween(prev, null);
      await (update(tasks)..where((r) => r.id.equals(t.id))).write(
        TasksCompanion(
          groupId: Value(target.id),
          sortKey: Value(prev),
          updatedAt: Value(now),
        ),
      );
    }
    await (update(taskGroups)..where((g) => g.id.equals(id))).write(
      TaskGroupsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  });
}
