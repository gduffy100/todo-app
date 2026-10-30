/// Label colour palette (ARGB). Labels store the ARGB int directly, so a
/// custom colour outside the palette is also valid.
const labelPalette = <int>[
  0xFFE53935, // red
  0xFFD81B60, // pink
  0xFF8E24AA, // purple
  0xFF5E35B1, // deep purple
  0xFF3949AB, // indigo
  0xFF1E88E5, // blue
  0xFF039BE5, // light blue
  0xFF00ACC1, // cyan
  0xFF00897B, // teal
  0xFF43A047, // green
  0xFF7CB342, // light green
  0xFFC0CA33, // lime
  0xFFFDD835, // yellow
  0xFFFB8C00, // orange
  0xFF6D4C41, // brown
  0xFF757575, // grey
];

/// Default labels seeded on first launch: (name, colour).
const defaultLabels = <(String, int)>[
  ('Gardening', 0xFF43A047),
  ('Home Improvement', 0xFFFB8C00),
  ('Shopping', 0xFF1E88E5),
  ('Work', 0xFF5E35B1),
  ('Personal', 0xFFD81B60),
];

const defaultGroups = <String>['Today', 'Tomorrow', 'Longer term'];
