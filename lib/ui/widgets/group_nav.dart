import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../state/providers.dart';
import '../screens/manage_groups_screen.dart';

/// Wraps a group destination so tasks can be dragged onto it to move them.
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
      onWillAcceptWithDetails: (_) => true,
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

/// Horizontal group bar shown at the bottom on compact/medium layouts.
class GroupBar extends ConsumerWidget {
  const GroupBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider).value ?? const [];
    final current = ref.watch(currentGroupProvider);
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
                        child: ChoiceChip(
                          label: Text(g.name),
                          selected: g.id == current?.id,
                          side: hovering
                              ? BorderSide(color: scheme.primary, width: 2)
                              : null,
                          onSelected: (_) => _select(ref, g),
                        ),
                      ),
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Add group',
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

/// Vertical group rail shown on the expanded (tablet landscape / desktop)
/// layout.
class GroupRail extends ConsumerWidget {
  const GroupRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider).value ?? const [];
    final current = ref.watch(currentGroupProvider);
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 220,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Text(
              'Groups',
              style: Theme.of(context).textTheme.titleSmall,
            ),
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
                  selected: g.id == current?.id,
                  selectedTileColor: scheme.secondaryContainer,
                  leading: Icon(
                    g.isSystem ? Icons.event_note_outlined : Icons.folder_open,
                  ),
                  title: Text(g.name),
                  onTap: () => _select(ref, g),
                  onLongPress: () => showGroupMenu(context, ref, g),
                ),
              ),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.add),
            title: const Text('Add group'),
            onTap: () => addGroup(context, ref),
          ),
        ],
      ),
    );
  }
}

void _select(WidgetRef ref, TaskGroup g) {
  ref.read(selectedGroupIdProvider.notifier).set(g.id);
  ref.read(selectedTaskIdProvider.notifier).set(null);
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
  final name = await showNameDialog(context, title: 'New group');
  if (name == null) return;
  final id = await ref.read(databaseProvider).groupsDao.createGroup(name);
  ref.read(selectedGroupIdProvider.notifier).set(id);
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
            title: const Text('Manage groups'),
            onTap: () => Navigator.pop(context, 'manage'),
          ),
          if (!group.isSystem)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete group'),
              subtitle: const Text('Its tasks move to the first group'),
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
        title: 'Rename group',
        initial: group.name,
      );
      if (name != null) await dao.renameGroup(group.id, name);
    case 'manage':
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ManageGroupsScreen()),
      );
    case 'delete':
      await dao.deleteGroup(group.id);
      ref.read(selectedGroupIdProvider.notifier).set(null);
  }
}
