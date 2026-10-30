import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/data/db.dart';
import 'package:todo_app/main.dart';
import 'package:todo_app/state/providers.dart';

const compactSize = Size(400, 800);
const mediumSize = Size(800, 1100);
const expandedSize = Size(1280, 800);

AppDatabase memoryDb() => AppDatabase(
  DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
);

/// Pumps the full app at [size] against an in-memory database.
Future<AppDatabase> pumpApp(
  WidgetTester tester,
  Size size, {
  Future<void> Function(AppDatabase db)? seed,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = memoryDb();
  if (seed != null) await seed(db);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const TodoApp(),
    ),
  );
  await settle(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
  return db;
}

/// Lets Drift streams emit and animations finish without requiring idle.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<String> groupId(AppDatabase db, String name) async =>
    (await db.groupsDao.getGroups()).firstWhere((g) => g.name == name).id;

Future<String> labelId(AppDatabase db, String name) async =>
    (await db.labelsDao.getLabels()).firstWhere((l) => l.name == name).id;
