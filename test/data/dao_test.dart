import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/data/db.dart';
import 'package:todo_app/domain/dependency_graph.dart';
import 'package:todo_app/domain/palette.dart';

void main() {
  late AppDatabase db;
  late String today, tomorrow;

  setUp(() async {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    final groups = await db.groupsDao.getGroups();
    today = groups[0].id;
    tomorrow = groups[1].id;
  });

  tearDown(() => db.close());

  Future<List<String>> titles(String groupId) async =>
      (await db.tasksDao.loadViews(groupId: groupId))
          .map((v) => v.task.title)
          .toList();

  group('seed', () {
    test('creates default groups in order and default labels', () async {
      final groups = await db.groupsDao.getGroups();
      expect(groups.map((g) => g.name), defaultGroups);
      expect(groups.every((g) => g.isSystem), isTrue);
      final labels = await db.labelsDao.getLabels();
      expect(labels.length, defaultLabels.length);
    });
  });

  group('tasks', () {
    test('create appends to the end of the group', () async {
      await db.tasksDao.createTask(title: 'a', groupId: today);
      await db.tasksDao.createTask(title: 'b', groupId: today);
      await db.tasksDao.createTask(title: 'c', groupId: today);
      expect(await titles(today), ['a', 'b', 'c']);
    });

    test('reorder moves only the moved row', () async {
      final a = await db.tasksDao.createTask(title: 'a', groupId: today);
      await db.tasksDao.createTask(title: 'b', groupId: today);
      final c = await db.tasksDao.createTask(title: 'c', groupId: today);
      final before = {
        for (final v in await db.tasksDao.loadViews(groupId: today))
          v.id: v.task.sortKey,
      };

      await db.tasksDao.reorder(c, 0);
      expect(await titles(today), ['c', 'a', 'b']);
      await db.tasksDao.reorder(a, 2);
      expect(await titles(today), ['c', 'b', 'a']);

      final after = await db.tasksDao.loadViews(groupId: today);
      final b = after.firstWhere((v) => v.task.title == 'b');
      expect(b.task.sortKey, before[b.id], reason: 'untouched sibling');
    });

    test('moveToGroup moves between groups and bumps updatedAt', () async {
      final id = await db.tasksDao.createTask(title: 'x', groupId: today);
      final created = (await db.tasksDao.loadViews()).single.task;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await db.tasksDao.moveToGroup(id, tomorrow);

      expect(await titles(today), isEmpty);
      expect(await titles(tomorrow), ['x']);
      final moved = (await db.tasksDao.loadViews()).single.task;
      expect(moved.updatedAt.isAfter(created.updatedAt), isTrue);
    });

    test('moveToGroup at index inserts in position', () async {
      await db.tasksDao.createTask(title: 'a', groupId: tomorrow);
      await db.tasksDao.createTask(title: 'b', groupId: tomorrow);
      final x = await db.tasksDao.createTask(title: 'x', groupId: today);
      await db.tasksDao.moveToGroup(x, tomorrow, index: 1);
      expect(await titles(tomorrow), ['a', 'x', 'b']);
    });

    test('delete is soft and hides the task', () async {
      final id = await db.tasksDao.createTask(title: 'gone', groupId: today);
      await db.tasksDao.deleteTask(id);
      expect(await titles(today), isEmpty);
      final raw = await db.select(db.tasks).get();
      expect(raw.single.deletedAt, isNotNull);
    });

    test('update and completion', () async {
      final id = await db.tasksDao.createTask(title: 't', groupId: today);
      final due = DateTime(2026, 11, 2);
      await db.tasksDao.updateTask(
        id,
        title: 'renamed',
        notes: 'n',
        dueDate: Value(due),
      );
      await db.tasksDao.setCompleted(id, true);
      var v = (await db.tasksDao.loadViews()).single;
      expect(v.task.title, 'renamed');
      expect(v.task.notes, 'n');
      expect(v.task.dueDate!.toLocal(), due);
      expect(v.isCompleted, isTrue);

      await db.tasksDao.updateTask(id, dueDate: const Value(null));
      await db.tasksDao.setCompleted(id, false);
      v = (await db.tasksDao.loadViews()).single;
      expect(v.task.dueDate, isNull);
      expect(v.isCompleted, isFalse);
    });

    test('overdue only for open tasks due before today', () async {
      final id = await db.tasksDao.createTask(
        title: 't',
        groupId: today,
        dueDate: DateTime(2026, 10, 1),
      );
      final now = DateTime(2026, 10, 30, 9);
      expect((await db.tasksDao.loadViews()).single.isOverdue(now), isTrue);
      await db.tasksDao.setCompleted(id, true);
      expect((await db.tasksDao.loadViews()).single.isOverdue(now), isFalse);
    });
  });

  group('labels', () {
    test('setLabels adds, removes and re-adds links', () async {
      final labels = await db.labelsDao.getLabels();
      final [l1, l2, l3, ...] = labels;
      final id = await db.tasksDao.createTask(
        title: 't',
        groupId: today,
        labelIds: {l1.id, l2.id},
      );
      Future<Set<String>> current() async => (await db.tasksDao.loadViews())
          .single
          .labels
          .map((l) => l.id)
          .toSet();

      expect(await current(), {l1.id, l2.id});
      await db.tasksDao.setLabels(id, {l2.id, l3.id});
      expect(await current(), {l2.id, l3.id});
      await db.tasksDao.setLabels(id, {l1.id});
      expect(await current(), {l1.id});
      // re-adding reuses the soft-deleted link row (unique task+label)
      expect((await db.select(db.taskLabels).get()).length, 3);
    });

    test('create, rename, recolour and delete a label', () async {
      final id = await db.labelsDao.createLabel('Garage', labelPalette[0]);
      await db.labelsDao.updateLabel(id, name: 'Car', color: labelPalette[3]);
      var l = (await db.labelsDao.getLabels()).firstWhere((l) => l.id == id);
      expect(l.name, 'Car');
      expect(l.color, labelPalette[3]);

      final t = await db.tasksDao.createTask(
        title: 't',
        groupId: today,
        labelIds: {id},
      );
      await db.labelsDao.deleteLabel(id);
      expect((await db.labelsDao.getLabels()).any((l) => l.id == id), isFalse);
      final v = (await db.tasksDao.loadViews()).firstWhere((v) => v.id == t);
      expect(v.labels, isEmpty);
    });
  });

  group('predecessors', () {
    test('blocked until predecessor completes', () async {
      final a = await db.tasksDao.createTask(title: 'a', groupId: today);
      final b = await db.tasksDao.createTask(title: 'b', groupId: tomorrow);
      await db.tasksDao.addPredecessor(b, a);

      var views = {for (final v in await db.tasksDao.loadViews()) v.id: v};
      expect(views[b]!.blocked, isTrue);
      expect(views[b]!.predecessorIds, [a]);
      expect(views[a]!.successorIds, [b]);

      await db.tasksDao.setCompleted(a, true);
      views = {for (final v in await db.tasksDao.loadViews()) v.id: v};
      expect(views[b]!.blocked, isFalse);
    });

    test('cycles are rejected', () async {
      final a = await db.tasksDao.createTask(title: 'a', groupId: today);
      final b = await db.tasksDao.createTask(title: 'b', groupId: today);
      final c = await db.tasksDao.createTask(title: 'c', groupId: today);
      await db.tasksDao.addPredecessor(b, a);
      await db.tasksDao.addPredecessor(c, b);
      expect(
        () => db.tasksDao.addPredecessor(a, c),
        throwsA(isA<CycleException>()),
      );
      expect(
        () => db.tasksDao.addPredecessor(a, a),
        throwsA(isA<CycleException>()),
      );
    });

    test('remove and re-add predecessor; delete clears edges', () async {
      final a = await db.tasksDao.createTask(title: 'a', groupId: today);
      final b = await db.tasksDao.createTask(title: 'b', groupId: today);
      await db.tasksDao.addPredecessor(b, a);
      await db.tasksDao.removePredecessor(b, a);
      var vb = (await db.tasksDao.loadViews()).firstWhere((v) => v.id == b);
      expect(vb.predecessorIds, isEmpty);

      await db.tasksDao.addPredecessor(b, a);
      await db.tasksDao.deleteTask(a);
      vb = (await db.tasksDao.loadViews()).firstWhere((v) => v.id == b);
      expect(vb.predecessorIds, isEmpty);
      expect(vb.blocked, isFalse);
    });
  });

  group('groups', () {
    test('create, rename and reorder', () async {
      final id = await db.groupsDao.createGroup('Someday');
      await db.groupsDao.renameGroup(id, 'Maybe');
      await db.groupsDao.reorderGroup(id, 0);
      final names = (await db.groupsDao.getGroups()).map((g) => g.name);
      expect(names, ['Maybe', ...defaultGroups]);
    });

    test('deleting a user group moves its tasks to the first group', () async {
      final id = await db.groupsDao.createGroup('Temp');
      await db.tasksDao.createTask(title: 'existing', groupId: today);
      await db.tasksDao.createTask(title: 'orphan', groupId: id);
      await db.groupsDao.deleteGroup(id);
      expect(await titles(today), ['existing', 'orphan']);
      expect((await db.groupsDao.getGroups()).any((g) => g.id == id), isFalse);
    });

    test('system groups cannot be deleted', () async {
      expect(() => db.groupsDao.deleteGroup(today), throwsStateError);
    });
  });

  test('watchGroupTasks re-emits when labels change', () async {
    final id = await db.tasksDao.createTask(title: 't', groupId: today);
    final label = (await db.labelsDao.getLabels()).first;
    final stream = db.tasksDao.watchGroupTasks(today);
    final expectation = expectLater(
      stream.map((vs) => vs.single.labels.length),
      emitsInOrder([0, 1]),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await db.tasksDao.setLabels(id, {label.id});
    await expectation;
  });
}
