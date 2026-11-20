import '../db.dart';

/// Converts local rows to and from the cloud's snake_case JSON.
///
/// `owner_id` and `server_updated_at` are decided by the server, so they are
/// read but never sent.
String _time(DateTime t) => t.toUtc().toIso8601String();
String? _timeOrNull(DateTime? t) => t?.toUtc().toIso8601String();
DateTime _parse(Object? v) => DateTime.parse(v! as String).toUtc();
DateTime? _parseOrNull(Object? v) =>
    v == null ? null : DateTime.parse(v as String).toUtc();

Map<String, dynamic> encodeGroup(TaskGroup g) => {
  'id': g.id,
  'name': g.name,
  'sort_key': g.sortKey,
  'is_system': g.isSystem,
  'created_at': _time(g.createdAt),
  'updated_at': _time(g.updatedAt),
  'deleted_at': _timeOrNull(g.deletedAt),
};

TaskGroup decodeGroup(Map<String, dynamic> r) => TaskGroup(
  id: r['id'] as String,
  ownerId: r['owner_id'] as String?,
  name: r['name'] as String,
  sortKey: r['sort_key'] as String,
  isSystem: r['is_system'] as bool,
  createdAt: _parse(r['created_at']),
  updatedAt: _parse(r['updated_at']),
  deletedAt: _parseOrNull(r['deleted_at']),
);

Map<String, dynamic> encodeTask(Task t) => {
  'id': t.id,
  'group_id': t.groupId,
  'title': t.title,
  'notes': t.notes,
  'sort_key': t.sortKey,
  'due_date': _timeOrNull(t.dueDate),
  'completed_at': _timeOrNull(t.completedAt),
  'created_at': _time(t.createdAt),
  'updated_at': _time(t.updatedAt),
  'deleted_at': _timeOrNull(t.deletedAt),
};

Task decodeTask(Map<String, dynamic> r) => Task(
  id: r['id'] as String,
  groupId: r['group_id'] as String,
  title: r['title'] as String,
  notes: r['notes'] as String,
  sortKey: r['sort_key'] as String,
  dueDate: _parseOrNull(r['due_date']),
  completedAt: _parseOrNull(r['completed_at']),
  createdAt: _parse(r['created_at']),
  updatedAt: _parse(r['updated_at']),
  deletedAt: _parseOrNull(r['deleted_at']),
);

Map<String, dynamic> encodeLabel(Label l) => {
  'id': l.id,
  'name': l.name,
  'color': l.color,
  'created_at': _time(l.createdAt),
  'updated_at': _time(l.updatedAt),
  'deleted_at': _timeOrNull(l.deletedAt),
};

Label decodeLabel(Map<String, dynamic> r) => Label(
  id: r['id'] as String,
  ownerId: r['owner_id'] as String?,
  name: r['name'] as String,
  color: (r['color'] as num).toInt(),
  createdAt: _parse(r['created_at']),
  updatedAt: _parse(r['updated_at']),
  deletedAt: _parseOrNull(r['deleted_at']),
);

Map<String, dynamic> encodeTaskLabel(TaskLabel l) => {
  'id': l.id,
  'task_id': l.taskId,
  'label_id': l.labelId,
  'created_at': _time(l.createdAt),
  'updated_at': _time(l.updatedAt),
  'deleted_at': _timeOrNull(l.deletedAt),
};

TaskLabel decodeTaskLabel(Map<String, dynamic> r) => TaskLabel(
  id: r['id'] as String,
  taskId: r['task_id'] as String,
  labelId: r['label_id'] as String,
  createdAt: _parse(r['created_at']),
  updatedAt: _parse(r['updated_at']),
  deletedAt: _parseOrNull(r['deleted_at']),
);

Map<String, dynamic> encodeDependency(TaskDependency d) => {
  'id': d.id,
  'task_id': d.taskId,
  'predecessor_id': d.predecessorId,
  'created_at': _time(d.createdAt),
  'updated_at': _time(d.updatedAt),
  'deleted_at': _timeOrNull(d.deletedAt),
};

TaskDependency decodeDependency(Map<String, dynamic> r) => TaskDependency(
  id: r['id'] as String,
  taskId: r['task_id'] as String,
  predecessorId: r['predecessor_id'] as String,
  createdAt: _parse(r['created_at']),
  updatedAt: _parse(r['updated_at']),
  deletedAt: _parseOrNull(r['deleted_at']),
);
