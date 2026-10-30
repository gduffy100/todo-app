import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/data/backup.dart';
import 'package:todo_app/data/db.dart';
import 'package:todo_app/domain/ordering.dart';
import 'package:todo_app/domain/palette.dart';
import 'package:todo_app/ui/widgets/label_widgets.dart';

import '../ui/harness.dart';

void main() {
  group('duplicate sort keys (e.g. after merging two devices)', () {
    test('keyAtIndex skips past tied neighbours', () {
      expect(keyAtIndex(['V', 'V'], 1).compareTo('V'), greaterThan(0));
      expect(keyAtIndex(['G', 'V', 'V', 'k'], 2), allOf(isNot('V')));
      final k = keyAtIndex(['G', 'V', 'V', 'k'], 2);
      expect(k.compareTo('V') > 0 && k.compareTo('k') < 0, isTrue);
      expect(keyAtIndex(['V', 'V'], 0).compareTo('V'), lessThan(0));
    });

    test('reordering among tasks with equal keys does not throw', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final today = await groupId(db, 'Today');
      final a = await db.tasksDao.createTask(title: 'a', groupId: today);
      final b = await db.tasksDao.createTask(title: 'b', groupId: today);
      final c = await db.tasksDao.createTask(title: 'c', groupId: today);
      // Force a tie, as two devices that each created a first task would.
      await (db.update(db.tasks)..where((t) => t.id.isIn([a, b]))).write(
        const TasksCompanion(sortKey: Value('V')),
      );
      // A drop inside a tied run lands just after it (only the moved row is
      // ever rewritten); a drop before the run lands before it.
      await db.tasksDao.reorder(c, 1);
      Future<List<String>> ids() async => [
        for (final v in await db.tasksDao.loadViews(groupId: today)) v.id,
      ];
      expect((await ids()).last, c);
      await db.tasksDao.reorder(c, 0);
      expect((await ids()).first, c);
    });
  });

  test(
    'toggleLabel adds and removes one label without touching others',
    () async {
      final db = memoryDb();
      addTearDown(db.close);
      final today = await groupId(db, 'Today');
      final g = await labelId(db, 'Gardening');
      final w = await labelId(db, 'Work');
      final id = await db.tasksDao.createTask(
        title: 't',
        groupId: today,
        labelIds: {g},
      );
      await db.tasksDao.toggleLabel(id, w, true);
      await db.tasksDao.toggleLabel(id, g, false);
      await db.tasksDao.toggleLabel(id, g, false); // idempotent
      final names = (await db.tasksDao.loadViews()).single.labels.map(
        (l) => l.name,
      );
      expect(names, ['Work']);
    },
  );

  group('import repair', () {
    test('cycles formed by merging two devices are broken', () async {
      final a = memoryDb();
      final b = memoryDb();
      addTearDown(a.close);
      addTearDown(b.close);
      final today = await groupId(a, 'Today');
      final t1 = await a.tasksDao.createTask(title: 't1', groupId: today);
      final t2 = await a.tasksDao.createTask(title: 't2', groupId: today);
      await Backup(b).importJson(await Backup(a).exportJson());

      await a.tasksDao.addPredecessor(t2, t1); // A: t1 before t2
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await b.tasksDao.addPredecessor(t1, t2); // B: t2 before t1

      await Backup(a).importJson(await Backup(b).exportJson());
      final views = {for (final v in await a.tasksDao.loadViews()) v.id: v};
      final edges =
          views[t1]!.predecessorIds.length + views[t2]!.predecessorIds.length;
      expect(edges, 1, reason: 'one edge kept, the newer one dropped');
      expect(views[t2]!.predecessorIds, [t1], reason: 'older edge wins');
      expect(views[t1]!.blocked && views[t2]!.blocked, isFalse);
    });

    test('tasks landing in a locally deleted group are rehomed', () async {
      final a = memoryDb();
      final b = memoryDb();
      addTearDown(a.close);
      addTearDown(b.close);
      final temp = await a.groupsDao.createGroup('Temp');
      await Backup(b).importJson(await Backup(a).exportJson());
      await b.groupsDao.deleteGroup(temp);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await a.tasksDao.createTask(title: 'late', groupId: temp);
      // Strip A's (older) group row so B's deletion stands, as it would
      // when B deleted the group after A's last edit to it.
      final backup = jsonDecode(await Backup(a).exportJson()) as Map;
      backup['groups'] = [];
      await Backup(b).importJson(jsonEncode(backup));

      final today = await groupId(b, 'Today');
      final titles = (await b.tasksDao.loadViews(groupId: today))
          .map((v) => v.task.title);
      expect(titles, contains('late'));
    });
  });

  test('label text colour meets 4.5:1 contrast on every palette colour', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance() + 0.05;
      final lb = b.computeLuminance() + 0.05;
      return la > lb ? la / lb : lb / la;
    }

    for (final c in labelPalette) {
      final bg = Color(c);
      expect(
        contrast(bg, onLabelColor(bg)),
        greaterThanOrEqualTo(4.5),
        reason: c.toRadixString(16),
      );
    }
  });
}
