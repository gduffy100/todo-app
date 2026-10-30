import 'package:flutter/material.dart';

import '../../data/db.dart';
import '../../domain/palette.dart';

/// Readable text colour on a label background.
Color onLabelColor(Color c) =>
    c.computeLuminance() > 0.179 ? Colors.black : Colors.white;

class LabelChip extends StatelessWidget {
  const LabelChip({super.key, required this.label, this.dense = false});

  final Label label;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = Color(label.color);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 1 : 3,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label.name,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: onLabelColor(color), fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Labels collapsed to coloured dots; tap to expand into named chips.
class LabelDots extends StatefulWidget {
  const LabelDots({
    super.key,
    required this.labels,
    this.startExpanded = false,
  });

  final List<Label> labels;
  final bool startExpanded;

  @override
  State<LabelDots> createState() => _LabelDotsState();
}

class _LabelDotsState extends State<LabelDots> {
  late bool _expanded = widget.startExpanded;

  @override
  Widget build(BuildContext context) {
    if (widget.labels.isEmpty) return const SizedBox.shrink();
    final names = widget.labels.map((l) => l.name).join(', ');
    return Semantics(
      button: true,
      label: _expanded ? 'Hide labels' : 'Labels: $names',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.centerLeft,
            child: _expanded
                ? Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final l in widget.labels)
                        LabelChip(label: l, dense: true),
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final l in widget.labels)
                        Container(
                          key: ValueKey('dot-${l.id}'),
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: Color(l.color),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class PalettePicker extends StatelessWidget {
  const PalettePicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in labelPalette)
          Semantics(
            button: true,
            selected: c == selected,
            label: 'Colour ${labelPalette.indexOf(c) + 1}',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onSelected(c),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Color(c),
                  shape: BoxShape.circle,
                  border: c == selected
                      ? Border.all(
                          color: Theme.of(context).colorScheme.onSurface,
                          width: 3,
                        )
                      : null,
                ),
                child: c == selected
                    ? Icon(Icons.check, size: 18, color: onLabelColor(Color(c)))
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// Dialog to create or edit a label. Returns (name, colour) or null.
Future<(String, int)?> showLabelDialog(
  BuildContext context, {
  Label? existing,
}) {
  final controller = TextEditingController(text: existing?.name ?? '');
  var color = existing?.color ?? labelPalette[5];
  return showDialog<(String, int)>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void submit() {
          final name = controller.text.trim();
          if (name.isNotEmpty) Navigator.pop(context, (name, color));
        }

        return AlertDialog(
          title: Text(existing == null ? 'New label' : 'Edit label'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLength: 40,
                  decoration: const InputDecoration(labelText: 'Name'),
                  onSubmitted: (_) => submit(),
                ),
                const SizedBox(height: 8),
                PalettePicker(
                  selected: color,
                  onSelected: (c) => setState(() => color = c),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(onPressed: submit, child: const Text('Save')),
          ],
        );
      },
    ),
  );
}
