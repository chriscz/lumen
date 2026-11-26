// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../domain/home.dart';
import 'home_scope.dart';
import 'widgets/light_picker.dart';

/// Creates a room, or edits one when [room] is given.
class RoomEditorScreen extends StatefulWidget {
  const RoomEditorScreen({super.key, this.room});

  final Room? room;

  @override
  State<RoomEditorScreen> createState() => _RoomEditorScreenState();
}

class _RoomEditorScreenState extends State<RoomEditorScreen> {
  late final _name = TextEditingController(text: widget.room?.name ?? '');
  Set<String>? _selected;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final home = HomeScope.read(context);
    final room = widget.room;
    if (room == null) {
      await home.createRoom(_name.text, _selected!);
    } else {
      await home.updateRoom(room.copyWith(name: _name.text.trim()), _selected!);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    await HomeScope.read(context).deleteRoom(widget.room!.id);
    // Leave the group's own screen as well, which no longer has a group.
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    _selected ??= {if (widget.room != null) ...home.lightsIn(widget.room!.id).map((l) => l.id)};
    final valid = _name.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.room == null ? 'New group' : 'Edit group'),
        actions: [
          if (widget.room != null)
            IconButton(tooltip: 'Delete group', icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: TextField(
              key: const ValueKey('room-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Group name', hintText: 'Living room'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          LightPicker(
            lights: home.lights,
            selected: _selected!,
            onChanged: (s) => setState(() => _selected = s),
            subtitle: (l) => l.roomId != null && l.roomId != widget.room?.id
                ? 'In ${home.room(l.roomId!)?.name ?? 'another room'}'
                : null,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(onPressed: valid ? _save : null, child: const Text('Save')),
        ),
      ),
    );
  }
}
