import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../domain/label_filter.dart';

/// The app database. Overridden in tests with an in-memory instance.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final groupsProvider = StreamProvider<List<TaskGroup>>(
  (ref) => ref.watch(databaseProvider).groupsDao.watchGroups(),
);

final labelsProvider = StreamProvider<List<Label>>(
  (ref) => ref.watch(databaseProvider).labelsDao.watchLabels(),
);

final groupTasksProvider = StreamProvider.family<List<TaskView>, String>(
  (ref, groupId) =>
      ref.watch(databaseProvider).tasksDao.watchGroupTasks(groupId),
);

final allTasksProvider = StreamProvider<List<TaskView>>(
  (ref) => ref.watch(databaseProvider).tasksDao.watchAllTasks(),
);

/// Simple settable value holder.
class ValueHolder<T> extends Notifier<T> {
  ValueHolder(this._initial);
  final T _initial;
  @override
  T build() => _initial;
  void set(T value) => state = value;
}

/// Explicitly chosen group; null means "first group".
final selectedGroupIdProvider = NotifierProvider<ValueHolder<String?>, String?>(
  () => ValueHolder(null),
);

/// The group currently shown, resolving the default.
final currentGroupProvider = Provider<TaskGroup?>((ref) {
  final groups = ref.watch(groupsProvider).value ?? const [];
  if (groups.isEmpty) return null;
  final selected = ref.watch(selectedGroupIdProvider);
  return groups.firstWhere((g) => g.id == selected, orElse: () => groups.first);
});

/// Task open in the detail pane (expanded layout).
final selectedTaskIdProvider = NotifierProvider<ValueHolder<String?>, String?>(
  () => ValueHolder(null),
);

final labelFilterProvider =
    NotifierProvider<ValueHolder<LabelFilter>, LabelFilter>(
      () => ValueHolder(const LabelFilter()),
    );

final showCompletedProvider = NotifierProvider<ValueHolder<bool>, bool>(
  () => ValueHolder(true),
);

/// Tasks of the current group after label + completed filters.
final visibleTasksProvider = Provider<AsyncValue<List<TaskView>>>((ref) {
  final group = ref.watch(currentGroupProvider);
  if (group == null) return const AsyncValue.data([]);
  final filter = ref.watch(labelFilterProvider);
  final showCompleted = ref.watch(showCompletedProvider);
  return ref
      .watch(groupTasksProvider(group.id))
      .whenData(
        (tasks) => [
          for (final t in tasks)
            if ((showCompleted || !t.isCompleted) &&
                filter.matches(t.labels.map((l) => l.id)))
              t,
        ],
      );
});
