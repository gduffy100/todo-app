import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/daos/tasks_dao.dart';
import '../../data/models.dart';
import '../../domain/dependency_graph.dart';
import '../../state/providers.dart';
import 'label_widgets.dart';

/// Edits one task. Changes save immediately (text fields are debounced).
/// Used in the bottom sheet (compact/medium) and the detail pane (expanded).
class TaskEditor extends ConsumerStatefulWidget {
  const TaskEditor({super.key, required this.taskId, this.onClose});

  final String taskId;

  /// Shows a close button when non-null.
  final VoidCallback? onClose;

  @override
  ConsumerState<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends ConsumerState<TaskEditor> {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  Timer? _debounce;
  String? _loadedId;

  /// Held so the final debounced save can run from dispose(), where `ref`
  /// may no longer be used.
  late final TasksDao _dao = ref.read(databaseProvider).tasksDao;

  @override
  void dispose() {
    _flush();
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _flush);
  }

  void _flush() {
    if (_debounce == null) return;
    _debounce!.cancel();
    _debounce = null;
    final id = _loadedId;
    final title = _title.text.trim();
    if (id == null) return;
    _dao.updateTask(
      id,
      title: title.isEmpty ? null : title,
      notes: _notes.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(allTasksProvider).value;
    if (all == null) return const Center(child: CircularProgressIndicator());
    final view = all.where((v) => v.id == widget.taskId).firstOrNull;
    if (view == null) {
      return const Center(child: Text('This task no longer exists'));
    }
    if (_loadedId != view.id) {
      _flush();
      _loadedId = view.id;
      _title.text = view.task.title;
      _notes.text = view.task.notes;
    }

    final dao = _dao;
    final groups = ref.watch(groupsProvider).value ?? const [];
    final labels = ref.watch(labelsProvider).value ?? const [];
    final byId = {for (final v in all) v.id: v};
    final theme = Theme.of(context);
    final selectedLabelIds = view.labels.map((l) => l.id).toSet();

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(text, style: theme.textTheme.titleSmall),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Row(
          children: [
            Checkbox(
              value: view.isCompleted,
              semanticLabel: 'Completed',
              onChanged: (v) => dao.setCompleted(view.id, v ?? false),
            ),
            Expanded(
              child: TextField(
                key: const Key('editor-title'),
                controller: _title,
                style: theme.textTheme.titleLarge,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Task title',
                ),
                onChanged: (_) => _scheduleSave(),
                onEditingComplete: _flush,
              ),
            ),
            if (widget.onClose != null)
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: widget.onClose,
              ),
          ],
        ),
        TextField(
          key: const Key('editor-notes'),
          controller: _notes,
          minLines: 2,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'Notes',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => _scheduleSave(),
        ),
        heading('Group'),
        DropdownButtonFormField<String>(
          initialValue: view.task.groupId,
          key: ValueKey('group-${view.task.groupId}'),
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: [
            for (final g in groups)
              DropdownMenuItem(value: g.id, child: Text(g.name)),
          ],
          onChanged: (id) {
            if (id != null && id != view.task.groupId) {
              dao.moveToGroup(view.id, id);
            }
          },
        ),
        heading('Due date'),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.event),
              label: Text(
                view.task.dueDate == null
                    ? 'Set due date'
                    : DateFormat.yMMMEd().format(view.task.dueDate!.toLocal()),
              ),
              onPressed: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: view.task.dueDate?.toLocal() ?? now,
                  firstDate: DateTime(now.year - 5),
                  lastDate: DateTime(now.year + 10),
                );
                if (picked != null) {
                  await dao.updateTask(view.id, dueDate: Value(picked));
                }
              },
            ),
            if (view.task.dueDate != null)
              TextButton(
                onPressed: () =>
                    dao.updateTask(view.id, dueDate: const Value(null)),
                child: const Text('Clear'),
              ),
          ],
        ),
        heading('Labels'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final l in labels)
              FilterChip(
                key: ValueKey('editor-label-${l.id}'),
                avatar: CircleAvatar(
                  backgroundColor: Color(l.color),
                  radius: 6,
                ),
                label: Text(l.name),
                selected: selectedLabelIds.contains(l.id),
                selectedColor: Color(l.color).withValues(alpha: 0.35),
                onSelected: (on) => dao.setLabels(view.id, {
                  ...selectedLabelIds.where((x) => x != l.id),
                  if (on) l.id,
                }),
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('New label'),
              onPressed: () async {
                final result = await showLabelDialog(context);
                if (result == null) return;
                final id = await ref
                    .read(databaseProvider)
                    .labelsDao
                    .createLabel(result.$1, result.$2);
                await dao.setLabels(view.id, {...selectedLabelIds, id});
              },
            ),
          ],
        ),
        heading('Must be done after'),
        if (view.blocked)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(
                  Icons.lock_clock,
                  size: 16,
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(width: 6),
                const Flexible(
                  child: Text('Blocked until predecessors are completed'),
                ),
              ],
            ),
          ),
        for (final pid in view.predecessorIds)
          if (byId[pid] case final p?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                p.isCompleted
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                size: 20,
              ),
              title: Text(p.task.title),
              trailing: IconButton(
                tooltip: 'Remove predecessor',
                icon: const Icon(Icons.link_off),
                onPressed: () => dao.removePredecessor(view.id, pid),
              ),
            ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add_link),
            label: const Text('Add predecessor'),
            onPressed: () async {
              final candidates = all
                  .where(
                    (v) =>
                        v.id != view.id && !view.predecessorIds.contains(v.id),
                  )
                  .toList();
              final picked = await _pickTask(context, candidates);
              if (picked == null) return;
              try {
                await dao.addPredecessor(view.id, picked);
              } on CycleException catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(e.message)));
                }
              }
            },
          ),
        ),
        if (view.successorIds.isNotEmpty) ...[
          heading('Blocks'),
          for (final sid in view.successorIds)
            if (byId[sid] case final s?)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.subdirectory_arrow_right, size: 20),
                title: Text(s.task.title),
              ),
        ],
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete task'),
            onPressed: () async {
              _debounce?.cancel();
              _debounce = null;
              await dao.deleteTask(view.id);
              ref.read(selectedTaskIdProvider.notifier).set(null);
              widget.onClose?.call();
            },
          ),
        ),
      ],
    );
  }
}

Future<String?> _pickTask(BuildContext context, List<TaskView> candidates) {
  return showDialog<String>(
    context: context,
    builder: (context) {
      var query = '';
      return StatefulBuilder(
        builder: (context, setState) {
          final shown = candidates
              .where(
                (v) => v.task.title.toLowerCase().contains(query.toLowerCase()),
              )
              .toList();
          return AlertDialog(
            title: const Text('Choose predecessor'),
            content: SizedBox(
              width: 400,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search tasks',
                    ),
                    onChanged: (v) => setState(() => query = v),
                  ),
                  Expanded(
                    child: shown.isEmpty
                        ? const Center(child: Text('No matching tasks'))
                        : ListView(
                            children: [
                              for (final v in shown)
                                ListTile(
                                  title: Text(v.task.title),
                                  trailing: v.labels.isEmpty
                                      ? null
                                      : LabelDots(labels: v.labels),
                                  onTap: () => Navigator.pop(context, v.id),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      );
    },
  );
}
