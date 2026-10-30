import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../layout/breakpoints.dart';
import '../widgets/group_nav.dart';
import '../widgets/label_filter_bar.dart';
import '../widgets/task_editor.dart';
import '../widgets/task_list.dart';
import 'data_transfer.dart';
import 'labels_screen.dart';
import 'manage_groups_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = LayoutSize.fromWidth(constraints.maxWidth);
        return size == LayoutSize.expanded
            ? const _ExpandedLayout()
            : _SinglePaneLayout(size: size);
      },
    );
  }
}

/// Compact (phone portrait) and medium (phone landscape / tablet portrait).
class _SinglePaneLayout extends ConsumerWidget {
  const _SinglePaneLayout({required this.size});
  final LayoutSize size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(currentGroupProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(group?.name ?? 'To-Do'),
        actions: const [_MainMenu()],
      ),
      body: Column(
        children: [
          const LabelFilterBar(),
          Expanded(
            child: TaskList(size: size, onOpen: (t) => _openSheet(context, t)),
          ),
        ],
      ),
      floatingActionButton: const _AddTaskButton(),
      bottomNavigationBar: const GroupBar(),
    );
  }

  void _openSheet(BuildContext context, TaskView task) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.85,
          child: TaskEditor(
            taskId: task.id,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
}

/// Tablet landscape / desktop: group rail · task list · detail pane.
class _ExpandedLayout extends ConsumerWidget {
  const _ExpandedLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(currentGroupProvider);
    final selectedId = ref.watch(selectedTaskIdProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(group?.name ?? 'To-Do'),
        actions: const [_MainMenu()],
      ),
      floatingActionButton: const _AddTaskButton(selectAfterCreate: true),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      body: Row(
        children: [
          const GroupRail(),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 5,
            child: Column(
              children: [
                const LabelFilterBar(),
                Expanded(
                  child: TaskList(
                    size: LayoutSize.expanded,
                    onOpen: (t) =>
                        ref.read(selectedTaskIdProvider.notifier).set(t.id),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 4,
            child: ColoredBox(
              color: scheme.surfaceContainerLow,
              child: selectedId == null
                  ? Center(
                      child: Text(
                        'Select a task to see its details',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : TaskEditor(
                      key: ValueKey(selectedId),
                      taskId: selectedId,
                      onClose: () =>
                          ref.read(selectedTaskIdProvider.notifier).set(null),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddTaskButton extends ConsumerWidget {
  const _AddTaskButton({this.selectAfterCreate = false});
  final bool selectAfterCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FloatingActionButton(
      tooltip: 'Add task',
      onPressed: () async {
        final group = ref.read(currentGroupProvider);
        if (group == null) return;
        final title = await showNameDialog(context, title: 'New task');
        if (title == null) return;
        // New tasks pick up the active label filter so they stay visible.
        final filter = ref.read(labelFilterProvider);
        final id = await ref
            .read(databaseProvider)
            .tasksDao
            .createTask(
              title: title,
              groupId: group.id,
              labelIds: filter.labelIds,
            );
        if (selectAfterCreate) {
          ref.read(selectedTaskIdProvider.notifier).set(id);
        }
      },
      child: const Icon(Icons.add),
    );
  }
}

class _MainMenu extends ConsumerWidget {
  const _MainMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showCompleted = ref.watch(showCompletedProvider);
    return PopupMenuButton<String>(
      tooltip: 'Menu',
      onSelected: (v) {
        switch (v) {
          case 'completed':
            ref.read(showCompletedProvider.notifier).set(!showCompleted);
          case 'labels':
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LabelsScreen()),
            );
          case 'groups':
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ManageGroupsScreen(),
              ),
            );
          case 'export':
            exportData(context, ref);
          case 'import':
            importData(context, ref);
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 'completed',
          checked: showCompleted,
          child: const Text('Show completed'),
        ),
        const PopupMenuItem(value: 'labels', child: Text('Manage labels')),
        const PopupMenuItem(value: 'groups', child: Text('Manage groups')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'export', child: Text('Export data')),
        const PopupMenuItem(value: 'import', child: Text('Import data')),
      ],
    );
  }
}
