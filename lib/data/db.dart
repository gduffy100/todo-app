import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../domain/ordering.dart';
import '../domain/palette.dart';
import 'daos/groups_dao.dart';
import 'daos/labels_dao.dart';
import 'daos/sync_dao.dart';
import 'daos/tasks_dao.dart';
import 'tables.dart';

export 'tables.dart';

part 'db.g.dart';

@DriftDatabase(
  tables: [
    TaskGroups,
    Tasks,
    Labels,
    TaskLabels,
    TaskDependencies,
    SyncOutbox,
    SyncState,
  ],
  daos: [GroupsDao, TasksDao, LabelsDao, SyncDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openDefault());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _seed();
      await _createOutboxTriggers();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(taskGroups, taskGroups.ownerId);
        await m.addColumn(labels, labels.ownerId);
        await m.createTable(syncOutbox);
        await m.createTable(syncState);
        await m.createIndex(syncOutboxRow);
        await _createOutboxTriggers();
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Queues every insert and update for sync. Re-inserting gives an already
  /// queued row a new seq, which is how a push notices an edit made while
  /// sending. This is not INSERT OR REPLACE because SQLite lets the conflict
  /// policy of the statement that fired a trigger override the one inside it,
  /// which would make every upsert fail.
  Future<void> _createOutboxTriggers() async {
    for (final table in syncedTables) {
      for (final (suffix, event) in const [
        ('insert', 'INSERT'),
        ('update', 'UPDATE'),
      ]) {
        await customStatement(
          'CREATE TRIGGER outbox_${table}_$suffix AFTER $event ON $table '
          "BEGIN DELETE FROM sync_outbox WHERE row_table = '$table' "
          'AND row_id = NEW.id; '
          'INSERT INTO sync_outbox (row_table, row_id) '
          "VALUES ('$table', NEW.id); END",
        );
      }
    }
  }

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
