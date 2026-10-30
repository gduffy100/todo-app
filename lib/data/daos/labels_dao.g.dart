// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'labels_dao.dart';

// ignore_for_file: type=lint
mixin _$LabelsDaoMixin on DatabaseAccessor<AppDatabase> {
  $LabelsTable get labels => attachedDatabase.labels;
  $TaskGroupsTable get taskGroups => attachedDatabase.taskGroups;
  $TasksTable get tasks => attachedDatabase.tasks;
  $TaskLabelsTable get taskLabels => attachedDatabase.taskLabels;
  LabelsDaoManager get managers => LabelsDaoManager(this);
}

class LabelsDaoManager {
  final _$LabelsDaoMixin _db;
  LabelsDaoManager(this._db);
  $$LabelsTableTableManager get labels =>
      $$LabelsTableTableManager(_db.attachedDatabase, _db.labels);
  $$TaskGroupsTableTableManager get taskGroups =>
      $$TaskGroupsTableTableManager(_db.attachedDatabase, _db.taskGroups);
  $$TasksTableTableManager get tasks =>
      $$TasksTableTableManager(_db.attachedDatabase, _db.tasks);
  $$TaskLabelsTableTableManager get taskLabels =>
      $$TaskLabelsTableTableManager(_db.attachedDatabase, _db.taskLabels);
}
