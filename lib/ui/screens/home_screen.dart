import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
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
    return Scaffold(
      appBar: AppBar(title: const _Title(), actions: const [_MainMenu()]),
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

/// Tablet landscape / desktop: list rail · task list · detail pane.
class _ExpandedLayout extends ConsumerWidget {
  const _ExpandedLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedTaskIdProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const _Title(), actions: const [_MainMenu()]),
      floatingActionButton: const _AddTaskButton(selectAfterCreate: true),
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

/// App bar title: the list name, or a summary in the combined view.
class _Title extends ConsumerWidget {
  const _Title();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = ref.watch(currentListsProvider);
    final total = ref.watch(groupsProvider).value?.length ?? 0;
    final text = switch (shown.length) {
      0 => 'To-Do',
      1 => shown.single.name,
      2 => '${shown[0].name} + ${shown[1].name}',
      final n when n == total => 'All lists',
      final n => '$n lists',
    };
    return Text(text, overflow: TextOverflow.ellipsis);
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
        final lists = ref.read(currentListsProvider);
        if (lists.isEmpty) return;
        // New tasks pick up the active label filter so they stay visible.
        final filter = ref.read(labelFilterProvider);
        final selection = ref.read(selectedTaskIdProvider.notifier);
        final dao = ref.read(databaseProvider).tasksDao;
        final result = await _showNewTaskDialog(context, lists);
        if (result == null) return;
        final id = await dao.createTask(
          title: result.title,
          groupId: result.listId,
          labelIds: filter.labelIds,
        );
        if (selectAfterCreate) selection.set(id);
      },
      child: const Icon(Icons.add),
    );
  }
}

/// Asks for a task title and, in the combined view, which list it goes in.
Future<({String title, String listId})?> _showNewTaskDialog(
  BuildContext context,
  List<TaskGroup> lists,
) {
  final controller = TextEditingController();
  var listId = lists.first.id;
  return showDialog<({String title, String listId})>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void submit() {
          final title = controller.text.trim();
          if (title.isNotEmpty) {
            Navigator.pop(context, (title: title, listId: listId));
          }
        }

        return AlertDialog(
          title: const Text('New task'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Name'),
                onSubmitted: (_) => submit(),
              ),
              if (lists.length > 1)
                DropdownButtonFormField<String>(
                  initialValue: listId,
                  decoration: const InputDecoration(labelText: 'List'),
                  items: [
                    for (final l in lists)
                      DropdownMenuItem(value: l.id, child: Text(l.name)),
                  ],
                  onChanged: (v) => setState(() => listId = v ?? listId),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(onPressed: submit, child: const Text('Save')),
          ],
        );
      },
    ),
  );
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
        const PopupMenuItem(value: 'groups', child: Text('Manage lists')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'export', child: Text('Export data')),
        const PopupMenuItem(value: 'import', child: Text('Import data')),
      ],
    );
  }
}
