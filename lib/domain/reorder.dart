/// Converts a ReorderableListView drop on a (possibly filtered) visible list
/// into a target index in the full ordered list, where both lists exclude the
/// moved item. [oldIndex]/[newIndex] are as passed to `onReorderItem`
/// ([newIndex] is already adjusted for the removed item).
int fullIndexForVisibleDrop({
  required List<String> fullIds,
  required List<String> visibleIds,
  required int oldIndex,
  required int newIndex,
}) {
  final moved = visibleIds[oldIndex];
  final target = newIndex;
  final visible = [...visibleIds]..remove(moved);
  final full = [...fullIds]..remove(moved);
  if (visible.isEmpty) return 0;
  if (target < visible.length) return full.indexOf(visible[target]);
  return full.indexOf(visible.last) + 1;
}
