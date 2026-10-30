// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'groups_dao.dart';

// ignore_for_file: type=lint
mixin _$GroupsDaoMixin on DatabaseAccessor<AppDatabase> {
  $TaskGroupsTable get taskGroups => attachedDatabase.taskGroups;
  $TasksTable get tasks => attachedDatabase.tasks;
  GroupsDaoManager get managers => GroupsDaoManager(this);
}

class GroupsDaoManager {
  final _$GroupsDaoMixin _db;
  GroupsDaoManager(this._db);
  $$TaskGroupsTableTableManager get taskGroups =>
      $$TaskGroupsTableTableManager(_db.attachedDatabase, _db.taskGroups);
  $$TasksTableTableManager get tasks =>
      $$TasksTableTableManager(_db.attachedDatabase, _db.tasks);
}
