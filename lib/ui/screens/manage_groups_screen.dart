import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../widgets/group_nav.dart';

class ManageGroupsScreen extends ConsumerWidget {
  const ManageGroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider).value ?? const [];
    final dao = ref.read(databaseProvider).groupsDao;

    return Scaffold(
      appBar: AppBar(title: const Text('Lists')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add list',
        onPressed: () => addGroup(context, ref),
        child: const Icon(Icons.add),
      ),
      body: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        itemCount: groups.length,
        onReorderItem: (oldIndex, newIndex) =>
            dao.reorderGroup(groups[oldIndex].id, newIndex),
        itemBuilder: (context, i) {
          final g = groups[i];
          return ListTile(
            key: ValueKey(g.id),
            title: Text(g.name),
            subtitle: g.isSystem ? const Text('Default list') : null,
            onTap: () => showGroupMenu(context, ref, g),
            trailing: ReorderableDragStartListener(
              index: i,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  Icons.drag_handle,
                  semanticLabel: 'Reorder ${g.name}',
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
