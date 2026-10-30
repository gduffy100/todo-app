import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/data/db.dart';
import 'package:todo_app/ui/widgets/group_nav.dart';
import 'package:todo_app/ui/widgets/task_editor.dart';

import 'harness.dart';

Future<void> seedOne(AppDatabase db) async {
  final today = await groupId(db, 'Today');
  final id = await db.tasksDao.createTask(
    title: 'Plant tulips',
    groupId: today,
    notes: 'Front border\nUse bone meal',
    dueDate: DateTime.now().add(const Duration(days: 1)),
    labelIds: {await labelId(db, 'Gardening')},
  );
  final pre = await db.tasksDao.createTask(title: 'Buy bulbs', groupId: today);
  await db.tasksDao.addPredecessor(id, pre);
}

void main() {
  testWidgets('compact: bottom group bar, label dots, no detail pane', (
    tester,
  ) async {
    await pumpApp(tester, compactSize, seed: seedOne);

    expect(find.byType(GroupBar), findsOneWidget);
    expect(find.byType(GroupRail), findsNothing);
    expect(find.text('Plant tulips'), findsOneWidget);
    // Label collapsed to a dot: its name only appears in the filter bar.
    expect(find.text('Gardening'), findsOneWidget);
    expect(find.text('Front border'), findsNothing);
    expect(find.byType(TaskEditor), findsNothing);
  });

  testWidgets('compact: tapping label dots expands them', (tester) async {
    await pumpApp(tester, compactSize, seed: seedOne);
    await tester.tap(find.bySemanticsLabel('Labels: Gardening'));
    await settle(tester);
    expect(find.text('Gardening'), findsNWidgets(2));
  });

  testWidgets('medium: tiles show label names and notes preview', (
    tester,
  ) async {
    await pumpApp(tester, mediumSize, seed: seedOne);
    expect(find.byType(GroupBar), findsOneWidget);
    expect(find.text('Gardening'), findsNWidgets(2));
    expect(find.text('Front border'), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);
  });

  testWidgets('expanded: rail + list + detail pane with dependency counts', (
    tester,
  ) async {
    await pumpApp(tester, expandedSize, seed: seedOne);
    expect(find.byType(GroupRail), findsOneWidget);
    expect(find.byType(GroupBar), findsNothing);
    expect(find.text('1 before'), findsOneWidget);
    expect(find.text('1 after'), findsOneWidget);
    expect(find.text('Select a task to see its details'), findsOneWidget);

    await tester.tap(find.text('Plant tulips'));
    await settle(tester);
    expect(find.byType(TaskEditor), findsOneWidget);
    expect(find.text('Must be done after'), findsOneWidget);
  });

  testWidgets('compact: tapping a task opens the editor sheet', (tester) async {
    await pumpApp(tester, compactSize, seed: seedOne);
    await tester.tap(find.text('Buy bulbs'));
    await settle(tester);
    expect(find.byType(TaskEditor), findsOneWidget);
  });
}
