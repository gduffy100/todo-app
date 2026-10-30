import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/label_filter.dart';
import '../../state/providers.dart';

/// Horizontal row of label filter chips with an Any/All toggle.
class LabelFilterBar extends ConsumerWidget {
  const LabelFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(labelsProvider).value ?? const [];
    if (labels.isEmpty) return const SizedBox.shrink();
    final filter = ref.watch(labelFilterProvider);
    final notifier = ref.read(labelFilterProvider.notifier);

    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          if (filter.isActive) ...[
            ActionChip(
              avatar: const Icon(Icons.close, size: 16),
              label: const Text('Clear'),
              onPressed: () => notifier.set(LabelFilter(match: filter.match)),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              label: Text(filter.match == LabelMatch.any ? 'Any' : 'All'),
              tooltip: 'Match any or all selected labels',
              selected: true,
              showCheckmark: false,
              onSelected: (_) => notifier.set(
                filter.withMatch(
                  filter.match == LabelMatch.any
                      ? LabelMatch.all
                      : LabelMatch.any,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          for (final l in labels) ...[
            FilterChip(
              key: ValueKey('filter-${l.id}'),
              avatar: CircleAvatar(backgroundColor: Color(l.color), radius: 6),
              label: Text(l.name),
              selected: filter.labelIds.contains(l.id),
              selectedColor: Color(l.color).withValues(alpha: 0.35),
              onSelected: (_) => notifier.set(filter.toggle(l.id)),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}
