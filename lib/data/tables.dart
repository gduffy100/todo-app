import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();
DateTime nowUtc() => DateTime.now().toUtc();

/// Columns every table carries so a future last-write-wins sync can merge
/// rows by id + updated_at and propagate deletions via deleted_at.
mixin SyncColumns on Table {
  TextColumn get id => text().clientDefault(newId)();
  DateTimeColumn get createdAt => dateTime().clientDefault(nowUtc)();
  DateTimeColumn get updatedAt => dateTime().clientDefault(nowUtc)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('TaskGroup')
class TaskGroups extends Table with SyncColumns {
  TextColumn get name => text().withLength(min: 1, max: 60)();
  TextColumn get sortKey => text()();
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();
}

@DataClassName('Task')
class Tasks extends Table with SyncColumns {
  TextColumn get title => text().withLength(min: 1, max: 500)();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get groupId => text().references(TaskGroups, #id)();
  TextColumn get sortKey => text()();
  DateTimeColumn get dueDate => dateTime().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();
}

@DataClassName('Label')
class Labels extends Table with SyncColumns {
  TextColumn get name => text().withLength(min: 1, max: 40)();

  /// ARGB colour.
  IntColumn get color => integer()();
}

@DataClassName('TaskLabel')
class TaskLabels extends Table with SyncColumns {
  TextColumn get taskId => text().references(Tasks, #id)();
  TextColumn get labelId => text().references(Labels, #id)();

  @override
  List<Set<Column>> get uniqueKeys => [
    {taskId, labelId},
  ];
}

@DataClassName('TaskDependency')
class TaskDependencies extends Table with SyncColumns {
  @ReferenceName('predecessorEdges')
  TextColumn get taskId => text().references(Tasks, #id)();
  @ReferenceName('successorEdges')
  TextColumn get predecessorId => text().references(Tasks, #id)();

  @override
  List<Set<Column>> get uniqueKeys => [
    {taskId, predecessorId},
  ];
}
