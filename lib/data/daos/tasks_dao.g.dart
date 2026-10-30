// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tasks_dao.dart';

// ignore_for_file: type=lint
mixin _$TasksDaoMixin on DatabaseAccessor<AppDatabase> {
  $TaskGroupsTable get taskGroups => attachedDatabase.taskGroups;
  $TasksTable get tasks => attachedDatabase.tasks;
  $LabelsTable get labels => attachedDatabase.labels;
  $TaskLabelsTable get taskLabels => attachedDatabase.taskLabels;
  $TaskDependenciesTable get taskDependencies =>
      attachedDatabase.taskDependencies;
  TasksDaoManager get managers => TasksDaoManager(this);
}

class TasksDaoManager {
  final _$TasksDaoMixin _db;
  TasksDaoManager(this._db);
  $$TaskGroupsTableTableManager get taskGroups =>
      $$TaskGroupsTableTableManager(_db.attachedDatabase, _db.taskGroups);
  $$TasksTableTableManager get tasks =>
      $$TasksTableTableManager(_db.attachedDatabase, _db.tasks);
  $$LabelsTableTableManager get labels =>
      $$LabelsTableTableManager(_db.attachedDatabase, _db.labels);
  $$TaskLabelsTableTableManager get taskLabels =>
      $$TaskLabelsTableTableManager(_db.attachedDatabase, _db.taskLabels);
  $$TaskDependenciesTableTableManager get taskDependencies =>
      $$TaskDependenciesTableTableManager(
        _db.attachedDatabase,
        _db.taskDependencies,
      );
}
