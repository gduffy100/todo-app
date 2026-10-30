import 'db.dart';

/// A task with everything the list/detail UI needs to render it.
class TaskView {
  const TaskView({
    required this.task,
    required this.labels,
    required this.predecessorIds,
    required this.successorIds,
    required this.blocked,
  });

  final Task task;
  final List<Label> labels;
  final List<String> predecessorIds;
  final List<String> successorIds;

  /// True when any predecessor is not yet completed.
  final bool blocked;

  String get id => task.id;
  bool get isCompleted => task.completedAt != null;

  bool isOverdue(DateTime now) {
    final due = task.dueDate;
    if (due == null || isCompleted) return false;
    final today = DateTime(now.year, now.month, now.day);
    final dueLocal = due.toLocal();
    return DateTime(
      dueLocal.year,
      dueLocal.month,
      dueLocal.day,
    ).isBefore(today);
  }
}
