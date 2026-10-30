import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../widgets/label_widgets.dart';

class LabelsScreen extends ConsumerWidget {
  const LabelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(labelsProvider).value ?? const [];
    final dao = ref.read(databaseProvider).labelsDao;

    return Scaffold(
      appBar: AppBar(title: const Text('Labels')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New label',
        onPressed: () async {
          final r = await showLabelDialog(context);
          if (r != null) await dao.createLabel(r.$1, r.$2);
        },
        child: const Icon(Icons.add),
      ),
      body: ListView(
        children: [
          for (final l in labels)
            ListTile(
              key: ValueKey(l.id),
              leading: CircleAvatar(
                backgroundColor: Color(l.color),
                radius: 12,
              ),
              title: Text(l.name),
              onTap: () async {
                final r = await showLabelDialog(context, existing: l);
                if (r != null) {
                  await dao.updateLabel(l.id, name: r.$1, color: r.$2);
                }
              },
              trailing: IconButton(
                tooltip: 'Delete ${l.name}',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('Delete "${l.name}"?'),
                      content: const Text(
                        'The label is removed from all tasks.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (ok ?? false) await dao.deleteLabel(l.id);
                },
              ),
            ),
        ],
      ),
    );
  }
}
