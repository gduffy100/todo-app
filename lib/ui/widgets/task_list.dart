import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../data/models.dart';
import '../../domain/reorder.dart';
import '../../state/providers.dart';
import '../layout/breakpoints.dart';
import 'group_nav.dart';
import 'task_tile.dart';

/// Task list for the shown lists.
///
/// * One list: a plain reorderable list.
/// * Several lists (combined view): one section per list with a pinned
///   header. Dropping a task on a header moves it to that list.
/// * Drag the handle to reorder within a list; long-press anywhere else and
///   drop on a list (header, bar chip or rail item) to move the task there.
class TaskList extends ConsumerStatefulWidget {
  const TaskList({super.key, required this.size, required this.onOpen});

  final LayoutSize size;
  final void Function(TaskView task) onOpen;

  @override
  ConsumerState<TaskList> createState() => _TaskListState();
}

class _TaskListState extends ConsumerState<TaskList> {
  /// Per list: locally reordered tasks shown until the database stream
  /// re-emits (keyed by the list emitted at reorder time), so a drop doesn't
  /// briefly snap back.
  final _optimistic = <String, ({List<TaskView> base, List<TaskView> order})>{};

  List<TaskView> _resolve(ListSection section) {
    final pending = _optimistic[section.list.id];
    if (pending == null) return section.tasks;
    if (!identical(pending.base, section.tasks)) {
      _optimistic.remove(section.list.id);
      return section.tasks;
    }
    return pending.order;
  }

  Future<void> _reorder(
    ListSection section,
    List<TaskView> tasks,
    int oldIndex,
    int newIndex,
  ) async {
    final listId = section.list.id;
    final full = ref.read(groupTasksProvider(listId)).value ?? const [];
    final index = fullIndexForVisibleDrop(
      fullIds: full.map((t) => t.id).toList(),
      visibleIds: tasks.map((t) => t.id).toList(),
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    final moved = tasks[oldIndex];
    setState(() {
      _optimistic[listId] = (
        base: section.tasks,
        order: [...tasks]
          ..removeAt(oldIndex)
          ..insert(newIndex, moved),
      );
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(databaseProvider).tasksDao.reorder(moved.id, index);
    } catch (e) {
      if (mounted) setState(() => _optimistic.remove(listId));
      messenger.showSnackBar(SnackBar(content: Text('Could not reorder: $e')));
    }
  }

  Widget _item(TaskView view, int index, String? selectedId) {
    final size = widget.size;
    final tile = TaskTile(
      view: view,
      size: size,
      selected: size == LayoutSize.expanded && view.id == selectedId,
      onTap: () => widget.onOpen(view),
      onToggleComplete: (v) =>
          ref.read(databaseProvider).tasksDao.setCompleted(view.id, v),
      dragHandle: ReorderableDragStartListener(
        index: index,
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
  }

  @override
  Widget build(BuildContext context) {
    final visible = ref.watch(visibleSectionsProvider);
    final selectedId = ref.watch(selectedTaskIdProvider);

    return visible.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Could not load tasks: $e')),
      data: (sections) {
        final resolved = [for (final s in sections) (s, _resolve(s))];
        if (resolved.every((r) => r.$2.isEmpty)) {
          final filtered = ref.watch(labelFilterProvider).isActive;
          return _EmptyState(
            message: filtered
                ? 'No tasks match the selected labels'
                : sections.length == 1
                ? 'Nothing in ${sections.single.list.name} yet'
                : 'Nothing in these lists yet',
          );
        }

        if (resolved.length == 1) {
          final (section, tasks) = resolved.single;
          return ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: tasks.length,
            onReorderItem: (o, n) => _reorder(section, tasks, o, n),
            itemBuilder: (context, i) => _item(tasks[i], i, selectedId),
          );
        }

        return CustomScrollView(
          slivers: [
            for (final (section, tasks) in resolved)
              SliverMainAxisGroup(
                key: ValueKey('section-${section.list.id}'),
                slivers: [
                  PinnedHeaderSliver(
                    child: _SectionHeader(
                      list: section.list,
                      count: tasks.length,
                    ),
                  ),
                  if (tasks.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Text('No tasks'),
                      ),
                    )
                  else
                    SliverReorderableList(
                      itemCount: tasks.length,
                      onReorderItem: (o, n) => _reorder(section, tasks, o, n),
                      itemBuilder: (context, i) =>
                          _item(tasks[i], i, selectedId),
                    ),
                ],
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 88)),
          ],
        );
      },
    );
  }
}

/// Pinned section header in the combined view; also a drop target.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.list, required this.count});
  final TaskGroup list;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GroupDropTarget(
      group: list,
      builder: (context, hovering) => Material(
        color: hovering ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  list.name,
                  style: theme.textTheme.titleSmall,
                  semanticsLabel: '${list.name}, $count tasks',
                ),
              ),
              Text(
                '$count',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
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
