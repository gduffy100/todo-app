import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  testWidgets('add a task with the FAB', (tester) async {
    final db = await pumpApp(tester, compactSize);
    await tester.tap(find.byTooltip('Add task'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Fix fence');
    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(find.text('Fix fence'), findsOneWidget);
    final today = await groupId(db, 'Today');
    final views = await db.tasksDao.loadViews(groupId: today);
    expect(views.single.task.title, 'Fix fence');
  });

  testWidgets('long-press drag a task onto a group chip moves it', (
    tester,
  ) async {
    final db = await pumpApp(
      tester,
      compactSize,
      seed: (db) async => db.tasksDao.createTask(
        title: 'Mow lawn',
        groupId: await groupId(db, 'Today'),
      ),
    );

    final start = tester.getCenter(find.text('Mow lawn'));
    final target = tester.getCenter(find.text('Tomorrow'));
    final gesture = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.moveTo(target + const Offset(1, 0));
    await tester.pump();
    await gesture.up();
    await settle(tester);

    expect(find.text('Mow lawn'), findsNothing);
    final tomorrow = await groupId(db, 'Tomorrow');
    expect(
      (await db.tasksDao.loadViews(groupId: tomorrow)).single.task.title,
      'Mow lawn',
    );

    await tester.tap(find.text('Tomorrow'));
    await settle(tester);
    expect(find.text('Mow lawn'), findsOneWidget);
  });

  testWidgets('label filter narrows the list (Any / All)', (tester) async {
    await pumpApp(
      tester,
      mediumSize,
      seed: (db) async {
        final today = await groupId(db, 'Today');
        final garden = await labelId(db, 'Gardening');
        final home = await labelId(db, 'Home Improvement');
        await db.tasksDao.createTask(
          title: 'Both',
          groupId: today,
          labelIds: {garden, home},
        );
        await db.tasksDao.createTask(
          title: 'Garden only',
          groupId: today,
          labelIds: {garden},
        );
        await db.tasksDao.createTask(title: 'None', groupId: today);
      },
    );
    Finder filterChip(String name) => find.widgetWithText(FilterChip, name);

    await tester.tap(filterChip('Gardening'));
    await settle(tester);
    expect(find.text('None'), findsNothing);
    expect(find.text('Both'), findsOneWidget);
    expect(find.text('Garden only'), findsOneWidget);

    await tester.tap(filterChip('Home Improvement'));
    await settle(tester);
    expect(find.text('Garden only'), findsOneWidget, reason: 'Any mode');

    await tester.tap(find.text('Any'));
    await settle(tester);
    expect(find.text('Garden only'), findsNothing, reason: 'All mode');
    expect(find.text('Both'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await settle(tester);
    expect(find.text('None'), findsOneWidget);
  });

  testWidgets('completing a task via its checkbox', (tester) async {
    final db = await pumpApp(
      tester,
      compactSize,
      seed: (db) async => db.tasksDao.createTask(
        title: 'Water plants',
        groupId: await groupId(db, 'Today'),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Complete Water plants'));
    await settle(tester);
    expect((await db.tasksDao.loadViews()).single.isCompleted, isTrue);
  });
}
