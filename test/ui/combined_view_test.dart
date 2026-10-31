import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/data/db.dart';

import 'harness.dart';

Future<void> seedTwo(AppDatabase db) async {
  await db.tasksDao.createTask(
    title: 'Mow lawn',
    groupId: await groupId(db, 'Today'),
  );
  await db.tasksDao.createTask(
    title: 'Buy paint',
    groupId: await groupId(db, 'Tomorrow'),
  );
}

Finder header(String list) =>
    find.bySemanticsLabel(RegExp('^$list, \\d+ tasks'));

Future<void> combine(WidgetTester tester, List<String> add) async {
  await tester.tap(find.byTooltip('Combine lists'));
  await settle(tester);
  for (final name in add) {
    await tester.tap(find.widgetWithText(FilterChip, name));
    await settle(tester);
  }
}

void main() {
  testWidgets('combining two lists shows a section per list', (tester) async {
    await pumpApp(tester, compactSize, seed: seedTwo);
    expect(find.text('Buy paint'), findsNothing);

    await combine(tester, ['Tomorrow']);

    expect(find.text('Today + Tomorrow'), findsOneWidget);
    expect(header('Today'), findsOneWidget);
    expect(header('Tomorrow'), findsOneWidget);
    expect(find.text('Mow lawn'), findsOneWidget);
    expect(find.text('Buy paint'), findsOneWidget);
  });

  testWidgets('All selects every list; leaving combine mode collapses', (
    tester,
  ) async {
    await pumpApp(tester, compactSize, seed: seedTwo);
    await tester.tap(find.byTooltip('Combine lists'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'All'));
    await settle(tester);
    expect(find.text('All lists'), findsOneWidget);
    expect(header('Longer term'), findsOneWidget);

    await tester.tap(find.byTooltip('Show one list'));
    await settle(tester);
    expect(header('Today'), findsNothing);
    expect(find.text('Buy paint'), findsNothing);
  });

  testWidgets('dragging a task onto another section header moves it', (
    tester,
  ) async {
    final db = await pumpApp(tester, compactSize, seed: seedTwo);
    await combine(tester, ['Tomorrow']);

    final start = tester.getCenter(find.text('Mow lawn'));
    final target = tester.getCenter(header('Tomorrow'));
    final gesture = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.moveTo(target + const Offset(1, 0));
    await tester.pump();
    await gesture.up();
    await settle(tester);

    final tomorrow = await groupId(db, 'Tomorrow');
    final titles = (await db.tasksDao.loadViews(groupId: tomorrow))
        .map((v) => v.task.title)
        .toList();
    expect(titles, ['Buy paint', 'Mow lawn']);
  });

  testWidgets('new task in the combined view can target any shown list', (
    tester,
  ) async {
    final db = await pumpApp(tester, compactSize, seed: seedTwo);
    await combine(tester, ['Tomorrow']);

    await tester.tap(find.byTooltip('Add task'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Sand door');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await settle(tester);
    await tester.tap(find.text('Tomorrow').last);
    await settle(tester);
    await tester.tap(find.text('Save'));
    await settle(tester);

    final tomorrow = await groupId(db, 'Tomorrow');
    expect(
      (await db.tasksDao.loadViews(groupId: tomorrow)).map((v) => v.task.title),
      contains('Sand door'),
    );
  });

  testWidgets('expanded rail supports combining', (tester) async {
    await pumpApp(tester, expandedSize, seed: seedTwo);
    await tester.tap(find.byTooltip('Combine lists'));
    await settle(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Tomorrow'));
    await settle(tester);
    expect(header('Today'), findsOneWidget);
    expect(header('Tomorrow'), findsOneWidget);
    expect(find.text('Buy paint'), findsOneWidget);
  });
}
