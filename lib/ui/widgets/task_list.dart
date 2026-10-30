import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../domain/reorder.dart';
import '../../state/providers.dart';
import '../layout/breakpoints.dart';
import 'task_tile.dart';

/// Ordered task list for the current group.
///
/// * Drag the handle to reorder within the group.
/// * Long-press anywhere else on a task and drop it on a group in the
///   group bar / rail to move it there.
class TaskList extends ConsumerStatefulWidget {
  const TaskList({super.key, required this.size, required this.onOpen});

  final LayoutSize size;
  final void Function(TaskView task) onOpen;

  @override
  ConsumerState<TaskList> createState() => _TaskListState();
}

class _TaskListState extends ConsumerState<TaskList> {
  /// Locally reordered list shown until the database stream re-emits, so a
  /// drop doesn't briefly snap back to the old order.
  List<TaskView>? _optimistic;
  List<TaskView>? _optimisticBase;

  Future<void> _reorder(
    List<TaskView> tasks,
    int oldIndex,
    int newIndex,
  ) async {
    final group = ref.read(currentGroupProvider);
    if (group == null) return;
    final full = ref.read(groupTasksProvider(group.id)).value ?? const [];
    final index = fullIndexForVisibleDrop(
      fullIds: full.map((t) => t.id).toList(),
      visibleIds: tasks.map((t) => t.id).toList(),
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    final moved = tasks[oldIndex];
    setState(() {
      _optimisticBase = tasks;
      _optimistic = [...tasks]
        ..removeAt(oldIndex)
        ..insert(newIndex, moved);
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(databaseProvider).tasksDao.reorder(moved.id, index);
    } catch (e) {
      if (mounted) setState(() => _optimistic = null);
      messenger.showSnackBar(SnackBar(content: Text('Could not reorder: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = ref.watch(currentGroupProvider);
    final visible = ref.watch(visibleTasksProvider);
    final selectedId = ref.watch(selectedTaskIdProvider);
    final dao = ref.read(databaseProvider).tasksDao;
    final size = widget.size;

    return visible.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Could not load tasks: $e')),
      data: (fresh) {
        // A new emission from the database supersedes the optimistic order.
        if (_optimistic != null && !identical(fresh, _optimisticBase)) {
          _optimistic = null;
          _optimisticBase = null;
        }
        final tasks = _optimistic ?? fresh;
        if (tasks.isEmpty) {
          final filtered = ref.watch(labelFilterProvider).isActive;
          return _EmptyState(
            message: filtered
                ? 'No tasks match the selected labels'
                : 'Nothing in ${group?.name ?? 'this group'} yet',
          );
        }
        return ReorderableListView.builder(
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: tasks.length,
          onReorderItem: (oldIndex, newIndex) =>
              _reorder(tasks, oldIndex, newIndex),
          itemBuilder: (context, i) {
            final view = tasks[i];
            final tile = TaskTile(
              view: view,
              size: size,
              selected: size == LayoutSize.expanded && view.id == selectedId,
              onTap: () => widget.onOpen(view),
              onToggleComplete: (v) => dao.setCompleted(view.id, v),
              dragHandle: ReorderableDragStartListener(
                index: i,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    Icons.drag_indicator,
                    semanticLabel: 'Reorder ${view.task.title}',
                  ),
                ),
              ),
            );
            return LongPressDraggable<String>(
              key: ValueKey(view.id),
              data: view.id,
              hapticFeedbackOnStart: true,
              feedback: _DragFeedback(title: view.task.title),
              childWhenDragging: Opacity(opacity: 0.4, child: tile),
              child: tile,
            );
          },
        );
      },
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.drive_file_move_outline, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checklist, size: 48, color: color),
            const SizedBox(height: 12),
            Text(message, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }
}
