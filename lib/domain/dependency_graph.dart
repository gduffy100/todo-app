/// Predecessor graph helpers. An edge task → predecessor means the
/// predecessor must be finished before the task can start.
library;

class CycleException implements Exception {
  CycleException(this.message);
  final String message;
  @override
  String toString() => 'CycleException: $message';
}

/// Whether adding [predecessorId] as a predecessor of [taskId] would create a
/// cycle, given the existing [predecessorsOf] adjacency (task → predecessors).
bool wouldCreateCycle(
  Map<String, Set<String>> predecessorsOf,
  String taskId,
  String predecessorId,
) {
  if (taskId == predecessorId) return true;
  // Cycle iff taskId is already (transitively) a predecessor of predecessorId.
  final seen = <String>{};
  final stack = [predecessorId];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    if (!seen.add(current)) continue;
    for (final p in predecessorsOf[current] ?? const <String>{}) {
      if (p == taskId) return true;
      stack.add(p);
    }
  }
  return false;
}
