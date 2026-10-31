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

/// Which lists are shown. Empty means "the first list". More than one id
/// shows a combined, sectioned view.
class ListSelection extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Shows just [id].
  void selectOnly(String id) => state = {id};

  /// Adds or removes [id], always keeping at least one list selected.
  void toggle(String id, {required String fallbackId}) {
    final current = state.isEmpty ? {fallbackId} : state;
    final next = {...current};
    if (!next.remove(id)) next.add(id);
    state = next.isEmpty ? current : next;
  }

  void selectAll(Iterable<String> ids) => state = ids.toSet();
}

final selectedListIdsProvider = NotifierProvider<ListSelection, Set<String>>(
  ListSelection.new,
);

/// When on, tapping a list in the bar/rail adds it to the combined view
/// instead of switching to it.
final combineModeProvider = NotifierProvider<ValueHolder<bool>, bool>(
  () => ValueHolder(false),
);

/// The lists currently shown, in list order. Never empty while lists exist.
final currentListsProvider = Provider<List<TaskGroup>>((ref) {
  final groups = ref.watch(groupsProvider).value ?? const [];
  if (groups.isEmpty) return const [];
  final selected = ref.watch(selectedListIdsProvider);
  final shown = [
    for (final g in groups)
      if (selected.contains(g.id)) g,
  ];
  return shown.isEmpty ? [groups.first] : shown;
});

/// The first shown list: the default target for new tasks.
final currentGroupProvider = Provider<TaskGroup?>(
  (ref) => ref.watch(currentListsProvider).firstOrNull,
);

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

/// One section of the task view: a list and its visible tasks.
typedef ListSection = ({TaskGroup list, List<TaskView> tasks});

/// Visible tasks per shown list, after label and completed filters.
final visibleSectionsProvider = Provider<AsyncValue<List<ListSection>>>((ref) {
  final lists = ref.watch(currentListsProvider);
  final filter = ref.watch(labelFilterProvider);
  final showCompleted = ref.watch(showCompletedProvider);
  final sections = <ListSection>[];
  for (final list in lists) {
    final tasks = ref.watch(groupTasksProvider(list.id));
    if (tasks.hasError) {
      return AsyncValue.error(tasks.error!, tasks.stackTrace!);
    }
    final value = tasks.value;
    if (value == null) return const AsyncValue.loading();
    sections.add((
      list: list,
      tasks: [
        for (final t in value)
          if ((showCompleted || !t.isCompleted) &&
              filter.matches(t.labels.map((l) => l.id)))
            t,
      ],
    ));
  }
  return AsyncValue.data(sections);
});
