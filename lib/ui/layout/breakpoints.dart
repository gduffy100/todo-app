/// Width-based layout classes (Material 3 window size classes).
enum LayoutSize {
  /// Phone portrait.
  compact,

  /// Phone landscape / tablet portrait.
  medium,

  /// Tablet landscape / desktop: two-pane.
  expanded;

  static LayoutSize fromWidth(double width) {
    if (width < 600) return compact;
    if (width < 1024) return medium;
    return expanded;
  }
}
