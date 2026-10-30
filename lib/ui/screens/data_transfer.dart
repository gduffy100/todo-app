import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/backup.dart';
import '../../state/providers.dart';

/// Copies a JSON backup to the clipboard (interim device-to-device transfer
/// until cloud sync exists).
Future<void> exportData(BuildContext context, WidgetRef ref) async {
  final json = await Backup(ref.read(databaseProvider)).exportJson();
  await Clipboard.setData(ClipboardData(text: json));
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Data exported'),
      content: const Text(
        'A backup of all your tasks, groups and labels has been copied to '
        'the clipboard. Paste it into "Import data" on another device, or '
        'save it somewhere safe.',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Merges a pasted JSON backup (newest change wins per item).
Future<void> importData(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Import data'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Paste a backup. It is merged with your current data; for '
              'items on both devices the most recent change wins.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 8,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: 'Paste backup JSON here',
                suffixIcon: IconButton(
                  tooltip: 'Paste from clipboard',
                  icon: const Icon(Icons.content_paste),
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    controller.text = data?.text ?? '';
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Import'),
        ),
      ],
    ),
  );
  if (text == null || text.trim().isEmpty) return;
  String message;
  try {
    final n = await Backup(ref.read(databaseProvider)).importJson(text);
    message = 'Import complete: $n item${n == 1 ? '' : 's'} updated';
  } on FormatException catch (e) {
    message = 'Import failed: ${e.message}';
  } catch (_) {
    // The transaction rolled back, so nothing was changed.
    message = 'Import failed: the backup is damaged or incompatible';
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
