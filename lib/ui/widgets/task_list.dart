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
class TaskList extends ConsumerWidget {
  const TaskList({super.key, required this.size, required this.onOpen});

  final LayoutSize size;
  final void Function(TaskView task) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(currentGroupProvider);
    final visible = ref.watch(visibleTasksProvider);
    final selectedId = ref.watch(selectedTaskIdProvider);
    final dao = ref.read(databaseProvider).tasksDao;

    return visible.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Could not load tasks: $e')),
      data: (tasks) {
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
          onReorderItem: (oldIndex, newIndex) {
            final full =
                ref.read(groupTasksProvider(group!.id)).value ?? const [];
            final index = fullIndexForVisibleDrop(
              fullIds: full.map((t) => t.id).toList(),
              visibleIds: tasks.map((t) => t.id).toList(),
              oldIndex: oldIndex,
              newIndex: newIndex,
            );
            dao.reorder(tasks[oldIndex].id, index);
          },
          itemBuilder: (context, i) {
            final view = tasks[i];
            final tile = TaskTile(
              view: view,
              size: size,
              selected: size == LayoutSize.expanded && view.id == selectedId,
              onTap: () => onOpen(view),
              onToggleComplete: (v) => dao.setCompleted(view.id, v),
              dragHandle: ReorderableDragStartListener(
                index: i,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.drag_indicator, semanticLabel: 'Reorder'),
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
