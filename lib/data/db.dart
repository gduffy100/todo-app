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

  /// Seeds default groups and labels. Seeded rows get deterministic ids and
  /// an old timestamp so every device has the *same* rows (no duplicates when
  /// merging data between devices) and any user edit wins a later sync.
  Future<void> _seed() async {
    final groupKeys = initialKeys(defaultGroups.length);
    final seededAt = DateTime.utc(2000);
    String slug(String s) =>
        s.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    await batch((b) {
      for (var i = 0; i < defaultGroups.length; i++) {
        b.insert(
          taskGroups,
          TaskGroupsCompanion.insert(
            id: Value('seed-group-${slug(defaultGroups[i])}'),
            name: defaultGroups[i],
            sortKey: groupKeys[i],
            isSystem: const Value(true),
            createdAt: Value(seededAt),
            updatedAt: Value(seededAt),
          ),
        );
      }
      for (final (name, color) in defaultLabels) {
        b.insert(
          labels,
          LabelsCompanion.insert(
            id: Value('seed-label-${slug(name)}'),
            name: name,
            color: color,
            createdAt: Value(seededAt),
            updatedAt: Value(seededAt),
          ),
        );
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
