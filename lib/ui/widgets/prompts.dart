// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

/// Asks the user to confirm [action]; true only when they tap it.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    ) ==
    true;

extension SnackMessages on ScaffoldMessengerState {
  /// Shows [text] in place of the current snack bar, with an Undo action
  /// when [undo] is given. With [replace] off it queues behind it instead.
  void show(String text, {VoidCallback? undo, bool replace = true}) {
    if (replace) hideCurrentSnackBar();
    showSnackBar(
      SnackBar(
        content: Text(text),
        action: undo == null ? null : SnackBarAction(label: 'Undo', onPressed: undo),
      ),
    );
  }
}

/// Asks for a name; pops with it trimmed, or with nothing on Cancel.
class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key, required this.initial, this.title = 'Rename'});

  final String initial;
  final String title;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _controller.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Name'),
        onChanged: (_) => setState(() {}),
        onSubmitted: valid ? (v) => Navigator.pop(context, v.trim()) : null,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, _controller.text.trim()) : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
