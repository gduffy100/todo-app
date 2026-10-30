import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../domain/ordering.dart';
import '../domain/palette.dart';
import 'daos/groups_dao.dart';
import 'daos/labels_dao.dart';
import 'daos/tasks_dao.dart';
import 'tables.dart';

export 'tables.dart';

part 'db.g.dart';

@DriftDatabase(
  tables: [TaskGroups, Tasks, Labels, TaskLabels, TaskDependencies],
  daos: [GroupsDao, TasksDao, LabelsDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openDefault());

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _seed();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  Future<void> _seed() async {
    final groupKeys = initialKeys(defaultGroups.length);
    await batch((b) {
      for (var i = 0; i < defaultGroups.length; i++) {
        b.insert(
          taskGroups,
          TaskGroupsCompanion.insert(
            name: defaultGroups[i],
            sortKey: groupKeys[i],
            isSystem: const Value(true),
          ),
        );
      }
      for (final (name, color) in defaultLabels) {
        b.insert(labels, LabelsCompanion.insert(name: name, color: color));
      }
    });
  }

  static QueryExecutor _openDefault() => driftDatabase(
    name: 'todo',
    web: DriftWebOptions(
      sqlite3Wasm: Uri.parse('sqlite3.wasm'),
      driftWorker: Uri.parse('drift_worker.js'),
    ),
  );
}
