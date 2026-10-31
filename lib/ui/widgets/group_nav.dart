import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../state/providers.dart';
import '../screens/manage_groups_screen.dart';

/// Wraps a list destination so tasks can be dragged onto it to move them.
///
/// The `task_groups` table holds what the UI calls "lists".
class GroupDropTarget extends ConsumerWidget {
  const GroupDropTarget({
    super.key,
    required this.group,
    required this.builder,
  });

  final TaskGroup group;
  final Widget Function(BuildContext context, bool hovering) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DragTarget<String>(
      // Dropping a task onto the list it is already in would only move it to
      // the end, so refuse it.
      onWillAcceptWithDetails: (details) {
        final tasks = ref.read(allTasksProvider).value ?? const [];
        final task = tasks.where((t) => t.id == details.data).firstOrNull;
        return task == null || task.task.groupId != group.id;
      },
      onAcceptWithDetails: (details) async {
        await ref
            .read(databaseProvider)
            .tasksDao
            .moveToGroup(details.data, group.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text('Moved to ${group.name}'),
                duration: const Duration(seconds: 2),
              ),
            );
        }
      },
      builder: (context, candidates, _) =>
          builder(context, candidates.isNotEmpty),
    );
  }
}

/// Horizontal list bar shown at the bottom on compact/medium layouts.
class GroupBar extends ConsumerWidget {
  const GroupBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider).value ?? const [];
    final shown = {for (final g in ref.watch(currentListsProvider)) g.id};
    final combine = ref.watch(combineModeProvider);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainer,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            children: [
              _CombineToggle(combine: combine),
              if (combine)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    label: const Text('All'),
                    selected: shown.length == groups.length,
                    onSelected: (_) => ref
                        .read(selectedListIdsProvider.notifier)
                        .selectAll(groups.map((g) => g.id)),
                  ),
                ),
              for (final g in groups)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GroupDropTarget(
                    key: ValueKey('groupbar-${g.id}'),
                    group: g,
                    builder: (context, hovering) => AnimatedScale(
                      scale: hovering ? 1.12 : 1,
                      duration: const Duration(milliseconds: 120),
                      child: GestureDetector(
                        onLongPress: () => showGroupMenu(context, ref, g),
                        child: combine
                            ? FilterChip(
                                label: Text(g.name),
                                selected: shown.contains(g.id),
                                side: hovering
                                    ? BorderSide(
                                        color: scheme.primary,
                                        width: 2,
                                      )
                                    : null,
                                onSelected: (_) => _tap(ref, g),
                              )
                            : ChoiceChip(
                                label: Text(g.name),
                                selected: shown.contains(g.id),
                                side: hovering
                                    ? BorderSide(
                                        color: scheme.primary,
                                        width: 2,
                                      )
                                    : null,
                                onSelected: (_) => _tap(ref, g),
                              ),
                      ),
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Add list',
                icon: const Icon(Icons.add),
                onPressed: () => addGroup(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Vertical list rail shown on the expanded (tablet landscape / desktop)
/// layout.
class GroupRail extends ConsumerWidget {
  const GroupRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider).value ?? const [];
    final shown = {for (final g in ref.watch(currentListsProvider)) g.id};
    final combine = ref.watch(combineModeProvider);
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 220,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 0, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Lists',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                _CombineToggle(combine: combine),
              ],
            ),
          ),
          if (combine)
            ListTile(
              dense: true,
              leading: const Icon(Icons.select_all),
              title: const Text('All lists'),
              onTap: () => ref
                  .read(selectedListIdsProvider.notifier)
                  .selectAll(groups.map((g) => g.id)),
            ),
          for (final g in groups)
            GroupDropTarget(
              key: ValueKey('grouprail-${g.id}'),
              group: g,
              builder: (context, hovering) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                    side: hovering
                        ? BorderSide(color: scheme.primary, width: 2)
                        : BorderSide.none,
                  ),
                  selected: shown.contains(g.id),
                  selectedTileColor: scheme.secondaryContainer,
                  leading: combine
                      ? Icon(
                          shown.contains(g.id)
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                        )
                      : Icon(
                          g.isSystem
                              ? Icons.event_note_outlined
                              : Icons.folder_open,
                        ),
                  title: Text(g.name),
                  onTap: () => _tap(ref, g),
                  onLongPress: () => showGroupMenu(context, ref, g),
                ),
              ),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.add),
            title: const Text('Add list'),
            onTap: () => addGroup(context, ref),
          ),
        ],
      ),
    );
  }
}

/// Switches to [g], or adds/removes it from the combined view in combine
/// mode.
void _tap(WidgetRef ref, TaskGroup g) {
  final selection = ref.read(selectedListIdsProvider.notifier);
  if (ref.read(combineModeProvider)) {
    selection.toggle(g.id, fallbackId: ref.read(currentGroupProvider)!.id);
  } else {
    selection.selectOnly(g.id);
    ref.read(selectedTaskIdProvider.notifier).set(null);
  }
}

/// Toggles combine mode. Leaving it collapses the view to the first list.
class _CombineToggle extends ConsumerWidget {
  const _CombineToggle({required this.combine});
  final bool combine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: combine ? 'Show one list' : 'Combine lists',
      isSelected: combine,
      icon: const Icon(Icons.layers_outlined),
      selectedIcon: const Icon(Icons.layers),
      onPressed: () {
        ref.read(combineModeProvider.notifier).set(!combine);
        if (combine) {
          final first = ref.read(currentGroupProvider);
          if (first != null) {
            ref.read(selectedListIdsProvider.notifier).selectOnly(first.id);
          }
        }
      },
    );
  }
}

Future<String?> showNameDialog(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      void submit() {
        final v = controller.text.trim();
        if (v.isNotEmpty) Navigator.pop(context, v);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (_) => submit(),
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
  );
}

Future<void> addGroup(BuildContext context, WidgetRef ref) async {
  final dao = ref.read(databaseProvider).groupsDao;
  final selection = ref.read(selectedListIdsProvider.notifier);
  final name = await showNameDialog(context, title: 'New list');
  if (name == null) return;
  selection.selectOnly(await dao.createGroup(name));
}

Future<void> showGroupMenu(
  BuildContext context,
  WidgetRef ref,
  TaskGroup group,
) async {
  final dao = ref.read(databaseProvider).groupsDao;
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text(group.name)),
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Rename'),
            onTap: () => Navigator.pop(context, 'rename'),
          ),
          ListTile(
            leading: const Icon(Icons.swap_vert),
            title: const Text('Manage lists'),
            onTap: () => Navigator.pop(context, 'manage'),
          ),
          if (!group.isSystem)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete list'),
              subtitle: const Text('Its tasks move to the first list'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  switch (action) {
    case 'rename':
      final name = await showNameDialog(
        context,
        title: 'Rename list',
        initial: group.name,
      );
      if (name != null) await dao.renameGroup(group.id, name);
    case 'manage':
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ManageGroupsScreen()),
      );
    case 'delete':
      final selection = ref.read(selectedListIdsProvider.notifier);
      await dao.deleteGroup(group.id);
      selection.selectAll(const []);
  }
}
