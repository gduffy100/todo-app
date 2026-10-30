import 'package:drift/drift.dart';

import '../../domain/dependency_graph.dart';
import '../../domain/ordering.dart';
import '../db.dart';
import '../models.dart';

part 'tasks_dao.g.dart';

@DriftAccessor(tables: [Tasks, Labels, TaskLabels, TaskDependencies])
class TasksDao extends DatabaseAccessor<AppDatabase> with _$TasksDaoMixin {
  TasksDao(super.db);

  // ---------------------------------------------------------------- reads

  /// Live tasks in [groupId], ordered by sort key. Re-emits whenever tasks,
  /// labels, label links or dependencies change.
  Stream<List<TaskView>> watchGroupTasks(String groupId) =>
      _watchViews(() => loadViews(groupId: groupId));

  /// Every live task (for predecessor pickers / search).
  Stream<List<TaskView>> watchAllTasks() => _watchViews(() => loadViews());

  Stream<List<TaskView>> _watchViews(Future<List<TaskView>> Function() load) =>
      customSelect(
        'SELECT 1',
        readsFrom: {tasks, labels, taskLabels, taskDependencies},
      ).watch().asyncMap((_) => load());

  Future<List<TaskView>> loadViews({String? groupId}) async {
    final query = select(tasks)
      ..where((t) {
        final live = t.deletedAt.isNull();
        return groupId == null ? live : live & t.groupId.equals(groupId);
      })
      ..orderBy([
        (t) => OrderingTerm.asc(t.sortKey),
        (t) => OrderingTerm.asc(t.id),
      ]);
    final rows = await query.get();
    if (rows.isEmpty) return const [];

    final labelRows =
        await (select(taskLabels).join([
                innerJoin(labels, labels.id.equalsExp(taskLabels.labelId)),
              ])
              ..where(
                taskLabels.deletedAt.isNull() &
                    labels.deletedAt.isNull() &
                    taskLabels.taskId.isIn(rows.map((r) => r.id)),
              )
              ..orderBy([OrderingTerm.asc(labels.name)]))
            .get();
    final labelsByTask = <String, List<Label>>{};
    for (final r in labelRows) {
      labelsByTask
          .putIfAbsent(r.readTable(taskLabels).taskId, () => [])
          .add(r.readTable(labels));
    }

    final deps = await _liveDependencies();
    final preds = <String, List<String>>{};
    final succs = <String, List<String>>{};
    for (final d in deps) {
      preds.putIfAbsent(d.taskId, () => []).add(d.predecessorId);
      succs.putIfAbsent(d.predecessorId, () => []).add(d.taskId);
    }
    final predIds = deps.map((d) => d.predecessorId).toSet();
    final openPreds = predIds.isEmpty
        ? <String>{}
        : (await (select(tasks)..where(
                    (t) =>
                        t.id.isIn(predIds) &
                        t.deletedAt.isNull() &
                        t.completedAt.isNull(),
                  ))
                  .get())
              .map((t) => t.id)
              .toSet();

    return [
      for (final t in rows)
        TaskView(
          task: t,
          labels: labelsByTask[t.id] ?? const [],
          predecessorIds: preds[t.id] ?? const [],
          successorIds: succs[t.id] ?? const [],
          blocked: (preds[t.id] ?? const []).any(openPreds.contains),
        ),
    ];
  }

  Future<List<TaskDependency>> _liveDependencies() =>
      (select(taskDependencies)..where((d) => d.deletedAt.isNull())).get();

  // ---------------------------------------------------------------- writes

  Future<String> createTask({
    required String title,
    required String groupId,
    String notes = '',
    DateTime? dueDate,
    Set<String> labelIds = const {},
  }) => transaction(() async {
    final key = await _keyAt(groupId, null, null);
    final row = await into(tasks).insertReturning(
      TasksCompanion.insert(
        title: title.trim(),
        groupId: groupId,
        sortKey: key,
        notes: Value(notes),
        dueDate: Value(dueDate?.toUtc()),
      ),
    );
    if (labelIds.isNotEmpty) await setLabels(row.id, labelIds);
    return row.id;
  });

  Future<void> updateTask(
    String id, {
    String? title,
    String? notes,
    Value<DateTime?> dueDate = const Value.absent(),
  }) => _write(
    id,
    TasksCompanion(
      title: title == null ? const Value.absent() : Value(title.trim()),
      notes: Value.absentIfNull(notes),
      dueDate: dueDate.present ? Value(dueDate.value?.toUtc()) : dueDate,
    ),
  );

  Future<void> setCompleted(String id, bool completed) => _write(
    id,
    TasksCompanion(completedAt: Value(completed ? nowUtc() : null)),
  );

  /// Moves a task into [groupId] at [index] (end of the list when null).
  Future<void> moveToGroup(String id, String groupId, {int? index}) =>
      transaction(() async {
        final key = await _keyAt(groupId, id, index);
        await _write(
          id,
          TasksCompanion(groupId: Value(groupId), sortKey: Value(key)),
        );
      });

  /// Reorders a task within its current group to [newIndex].
  Future<void> reorder(String id, int newIndex) => transaction(() async {
    final task = await (select(
      tasks,
    )..where((t) => t.id.equals(id))).getSingle();
    final key = await _keyAt(task.groupId, id, newIndex);
    await _write(id, TasksCompanion(sortKey: Value(key)));
  });

  /// Soft-deletes the task plus its label links and dependency edges.
  Future<void> deleteTask(String id) => transaction(() async {
    final now = nowUtc();
    await _write(id, TasksCompanion(deletedAt: Value(now)));
    await (update(
      taskLabels,
    )..where((tl) => tl.taskId.equals(id) & tl.deletedAt.isNull())).write(
      TaskLabelsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await (update(taskDependencies)..where(
          (d) =>
              (d.taskId.equals(id) | d.predecessorId.equals(id)) &
              d.deletedAt.isNull(),
        ))
        .write(
          TaskDependenciesCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  });

  /// Makes the task's live labels exactly [labelIds].
  Future<void> setLabels(String taskId, Set<String> labelIds) =>
      transaction(() async {
        final now = nowUtc();
        final existing = await (select(
          taskLabels,
        )..where((tl) => tl.taskId.equals(taskId))).get();
        final byLabel = {for (final e in existing) e.labelId: e};
        for (final e in existing) {
          final wanted = labelIds.contains(e.labelId);
          final live = e.deletedAt == null;
          if (wanted != live) {
            await (update(taskLabels)..where((tl) => tl.id.equals(e.id))).write(
              TaskLabelsCompanion(
                deletedAt: Value(wanted ? null : now),
                updatedAt: Value(now),
              ),
            );
          }
        }
        for (final labelId in labelIds.where((l) => !byLabel.containsKey(l))) {
          await into(taskLabels).insert(
            TaskLabelsCompanion.insert(taskId: taskId, labelId: labelId),
          );
        }
      });

  /// Adds or removes a single label on a task. Unlike [setLabels] this does
  /// not depend on a possibly stale snapshot of the task's other labels.
  Future<void> toggleLabel(String taskId, String labelId, bool on) =>
      transaction(() async {
        final now = nowUtc();
        final existing =
            await (select(taskLabels)..where(
                  (tl) => tl.taskId.equals(taskId) & tl.labelId.equals(labelId),
                ))
                .getSingleOrNull();
        if (existing == null) {
          if (on) {
            await into(taskLabels).insert(
              TaskLabelsCompanion.insert(taskId: taskId, labelId: labelId),
            );
          }
        } else if ((existing.deletedAt == null) != on) {
          await (update(
            taskLabels,
          )..where((tl) => tl.id.equals(existing.id))).write(
            TaskLabelsCompanion(
              deletedAt: Value(on ? null : now),
              updatedAt: Value(now),
            ),
          );
        }
      });

  /// Adds [predecessorId] as a predecessor of [taskId].
  /// Throws [CycleException] if that would create a dependency cycle.
  Future<void> addPredecessor(String taskId, String predecessorId) =>
      transaction(() async {
        final graph = <String, Set<String>>{};
        for (final d in await _liveDependencies()) {
          graph.putIfAbsent(d.taskId, () => {}).add(d.predecessorId);
        }
        if (wouldCreateCycle(graph, taskId, predecessorId)) {
          throw CycleException(
            'That predecessor would create a circular dependency',
          );
        }
        final now = nowUtc();
        final existing =
            await (select(taskDependencies)..where(
                  (d) =>
                      d.taskId.equals(taskId) &
                      d.predecessorId.equals(predecessorId),
                ))
                .getSingleOrNull();
        if (existing == null) {
          await into(taskDependencies).insert(
            TaskDependenciesCompanion.insert(
              taskId: taskId,
              predecessorId: predecessorId,
            ),
          );
        } else if (existing.deletedAt != null) {
          await (update(
            taskDependencies,
          )..where((d) => d.id.equals(existing.id))).write(
            TaskDependenciesCompanion(
              deletedAt: const Value(null),
              updatedAt: Value(now),
            ),
          );
        }
      });

  Future<void> removePredecessor(String taskId, String predecessorId) {
    final now = nowUtc();
    return (update(taskDependencies)..where(
          (d) =>
              d.taskId.equals(taskId) &
              d.predecessorId.equals(predecessorId) &
              d.deletedAt.isNull(),
        ))
        .write(
          TaskDependenciesCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  }

  // ---------------------------------------------------------------- helpers

  Future<void> _write(String id, TasksCompanion changes) =>
      (update(tasks)..where((t) => t.id.equals(id))).write(
        changes.copyWith(updatedAt: Value(nowUtc())),
      );

  /// Sort key for position [index] in [groupId], ignoring [excludeId]
  /// (the task being moved). A null index means "append at the end".
  Future<String> _keyAt(String groupId, String? excludeId, int? index) async {
    final siblings =
        await (select(tasks)
              ..where(
                (t) =>
                    t.groupId.equals(groupId) &
                    t.deletedAt.isNull() &
                    (excludeId == null
                        ? const Constant(true)
                        : t.id.equals(excludeId).not()),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.sortKey),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    return keyAtIndex([
      for (final t in siblings) t.sortKey,
    ], index ?? siblings.length);
  }
}
