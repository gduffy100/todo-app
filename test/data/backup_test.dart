import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/data/backup.dart';

import '../ui/harness.dart';

void main() {
  test('export then import into an empty device reproduces the data', () async {
    final a = memoryDb();
    final b = memoryDb();
    addTearDown(a.close);
    addTearDown(b.close);

    final today = await groupId(a, 'Today');
    final garden = await labelId(a, 'Gardening');
    final t1 = await a.tasksDao.createTask(
      title: 'One',
      groupId: today,
      labelIds: {garden},
    );
    final t2 = await a.tasksDao.createTask(title: 'Two', groupId: today);
    await a.tasksDao.addPredecessor(t2, t1);

    final written = await Backup(b).importJson(await Backup(a).exportJson());
    expect(written, greaterThan(0));

    // Seeded defaults share ids across devices, so nothing is duplicated.
    expect((await b.groupsDao.getGroups()).length, 3);
    expect((await b.labelsDao.getLabels()).length, 5);

    final views = await b.tasksDao.loadViews();
    expect(views.map((v) => v.task.title), containsAll(['One', 'Two']));
    final two = views.firstWhere((v) => v.task.title == 'Two');
    expect(two.predecessorIds, [t1]);
    expect(two.blocked, isTrue);
    expect(
      views.firstWhere((v) => v.task.title == 'One').labels.single.name,
      'Gardening',
    );
  });

  test('newer change wins and an older import does not overwrite', () async {
    final a = memoryDb();
    final b = memoryDb();
    addTearDown(a.close);
    addTearDown(b.close);

    final id = await a.tasksDao.createTask(
      title: 'Original',
      groupId: await groupId(a, 'Today'),
    );
    final snapshot = await Backup(a).exportJson();
    await Backup(b).importJson(snapshot);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.tasksDao.updateTask(id, title: 'Edited on B');
    // Re-importing the older snapshot must not revert the edit.
    expect(await Backup(b).importJson(snapshot), 0);
    expect((await b.tasksDao.loadViews()).single.task.title, 'Edited on B');

    // The newer edit flows back to A.
    await Backup(a).importJson(await Backup(b).exportJson());
    expect((await a.tasksDao.loadViews()).single.task.title, 'Edited on B');
  });

  test('rejects non-backup JSON', () async {
    final db = memoryDb();
    addTearDown(db.close);
    expect(() => Backup(db).importJson('{"hello": 1}'), throwsFormatException);
  });
}
