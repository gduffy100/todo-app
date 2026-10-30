import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../layout/breakpoints.dart';
import 'label_widgets.dart';

String formatDue(DateTime due, DateTime now) {
  final d = due.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  if (diff.abs() < 7) return DateFormat.E().format(d);
  return day.year == today.year
      ? DateFormat.MMMd().format(d)
      : DateFormat.yMMMd().format(d);
}

/// One task row. Detail increases with [size]:
/// compact = dots + due badge; medium = label chips + notes preview;
/// expanded = medium + predecessor/successor counts.
class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.view,
    required this.size,
    required this.onTap,
    required this.onToggleComplete,
    this.selected = false,
    this.dragHandle,
    this.now,
  });

  final TaskView view;
  final LayoutSize size;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggleComplete;
  final bool selected;
  final Widget? dragHandle;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = view.task;
    final clock = now ?? DateTime.now();
    final overdue = view.isOverdue(clock);
    final rich = size != LayoutSize.compact;

    final meta = <Widget>[
      if (t.dueDate != null)
        _MetaBadge(
          icon: Icons.event,
          text: formatDue(t.dueDate!, clock),
          color: overdue ? scheme.error : scheme.onSurfaceVariant,
        ),
      if (view.blocked)
        _MetaBadge(
          icon: Icons.lock_clock,
          text: rich ? 'Blocked' : '',
          color: scheme.tertiary,
          tooltip: 'Waiting on a predecessor',
        ),
      if (size == LayoutSize.expanded && view.predecessorIds.isNotEmpty)
        _MetaBadge(
          icon: Icons.call_merge,
          text: '${view.predecessorIds.length} before',
          color: scheme.onSurfaceVariant,
        ),
      if (size == LayoutSize.expanded && view.successorIds.isNotEmpty)
        _MetaBadge(
          icon: Icons.call_split,
          text: '${view.successorIds.length} after',
          color: scheme.onSurfaceVariant,
        ),
    ];

    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(4, rich ? 6 : 2, 4, rich ? 6 : 2),
          child: Row(
            crossAxisAlignment: rich
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              Checkbox(
                value: view.isCompleted,
                semanticLabel: 'Complete ${t.title}',
                onChanged: (v) => onToggleComplete(v ?? false),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.title,
                        maxLines: rich ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          decoration: view.isCompleted
                              ? TextDecoration.lineThrough
                              : null,
                          color: view.isCompleted
                              ? scheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                      if (rich && t.notes.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            t.notes.trim().split('\n').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (meta.isNotEmpty || view.labels.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (view.labels.isNotEmpty)
                                rich
                                    ? Wrap(
                                        spacing: 4,
                                        runSpacing: 4,
                                        children: [
                                          for (final l in view.labels)
                                            LabelChip(label: l, dense: true),
                                        ],
                                      )
                                    : LabelDots(labels: view.labels),
                              ...meta,
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              ?dragHandle,
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaBadge extends StatelessWidget {
  const _MetaBadge({
    required this.icon,
    required this.text,
    required this.color,
    this.tooltip,
  });

  final IconData icon;
  final String text;
  final Color color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        if (text.isNotEmpty) ...[
          const SizedBox(width: 3),
          Text(
            text,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: color),
          ),
        ],
      ],
    );
    return tooltip == null ? child : Tooltip(message: tooltip, child: child);
  }
}
