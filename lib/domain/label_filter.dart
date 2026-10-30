enum LabelMatch { any, all }

/// Label filter state. An empty [labelIds] set matches everything.
class LabelFilter {
  const LabelFilter({this.labelIds = const {}, this.match = LabelMatch.any});

  final Set<String> labelIds;
  final LabelMatch match;

  bool get isActive => labelIds.isNotEmpty;

  bool matches(Iterable<String> taskLabelIds) {
    if (labelIds.isEmpty) return true;
    final taskSet = taskLabelIds.toSet();
    return match == LabelMatch.any
        ? labelIds.any(taskSet.contains)
        : labelIds.every(taskSet.contains);
  }

  LabelFilter toggle(String labelId) {
    final next = {...labelIds};
    if (!next.remove(labelId)) next.add(labelId);
    return LabelFilter(labelIds: next, match: match);
  }

  LabelFilter withMatch(LabelMatch m) =>
      LabelFilter(labelIds: labelIds, match: m);
}
