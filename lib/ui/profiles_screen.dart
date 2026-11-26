// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/home.dart';
import 'home_scope.dart';
import 'profile_editor_screen.dart';
import 'widgets/profile_swatch.dart';
import 'widgets/prompts.dart';

class ProfilesScreen extends StatelessWidget {
  const ProfilesScreen({super.key});

  static Future<void> newProfile(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: const Text('Scene from my lights'),
              subtitle: const Text('Capture how chosen lights look right now'),
              onTap: () => Navigator.pop(context, 'scene'),
            ),
            ListTile(
              leading: const Icon(Icons.palette_rounded),
              title: const Text('New colour preset'),
              subtitle: const Text('One look you can apply to any lights'),
              onTap: () => Navigator.pop(context, 'preset'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => choice == 'scene' ? const SceneEditorScreen() : const PresetEditorScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final profiles = [...home.profiles]..sort((a, b) => (b.favorite ? 1 : 0) - (a.favorite ? 1 : 0));
    return Scaffold(
      appBar: AppBar(title: const Text('Profiles')),
      body: profiles.isEmpty
          ? const Center(child: Text('No profiles yet'))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: profiles.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _ProfileCard(profile: profiles[i]),
            ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile});

  final Profile profile;

  Future<void> _apply(BuildContext context) async {
    final home = HomeScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    HapticFeedback.selectionClick();
    int approximated;
    if (profile.isPreset) {
      final targets = await showModalBottomSheet<Set<String>>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => HomeScope(home: home, child: const _ApplySheet()),
      );
      if (targets == null || targets.isEmpty) return;
      approximated = await home.applyProfile(profile.id, to: targets);
    } else {
      approximated = await home.applyProfile(profile.id);
    }
    messenger.show(
      approximated == 0
          ? 'Applied ${profile.name}'
          : 'Applied ${profile.name}. Approximated on $approximated ${approximated == 1 ? 'light' : 'lights'}.',
    );
  }

  Future<void> _rename(BuildContext context) async {
    final home = HomeScope.read(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(initial: profile.name),
    );
    if (name != null) await home.updateProfile(profile.copyWith(name: name));
  }

  Future<void> _delete(BuildContext context) async {
    final home = HomeScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    await home.deleteProfile(profile.id);
    messenger.show('Deleted ${profile.name}', undo: () => home.restoreProfile(profile));
  }

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.read(context);
    final theme = Theme.of(context);
    final subtitle = profile.isPreset
        ? 'Preset'
        : 'Scene, ${profile.states.length} ${profile.states.length == 1 ? 'light' : 'lights'}';
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
        leading: ProfileSwatch(profile: profile),
        title: Text(profile.name, style: theme.textTheme.titleMedium),
        subtitle: Text(subtitle),
        onTap: () => _apply(context),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: profile.favorite ? 'Remove from Home' : 'Show on Home',
              icon: Icon(profile.favorite ? Icons.star_rounded : Icons.star_outline_rounded),
              onPressed: () => home.toggleProfileFavorite(profile.id),
            ),
            PopupMenuButton<String>(
              key: ValueKey('profile-menu-${profile.name}'),
              onSelected: (v) => v == 'rename' ? _rename(context) : _delete(context),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks the lights a preset goes to: everything, rooms or single lights.
class _ApplySheet extends StatefulWidget {
  const _ApplySheet();

  @override
  State<_ApplySheet> createState() => _ApplySheetState();
}

class _ApplySheetState extends State<_ApplySheet> {
  final Set<String> _lights = {};

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final all = home.lights.map((l) => l.id).toSet();
    final everything = all.isNotEmpty && _lights.containsAll(all);
    void toggle(Iterable<String> ids, bool on) => setState(() => on ? _lights.addAll(ids) : _lights.removeAll(ids));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Apply to', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(label: const Text('All lights'), selected: everything, onSelected: (v) => toggle(all, v)),
                for (final room in home.rooms)
                  FilterChip(
                    label: Text(room.name),
                    selected:
                        home.lightsIn(room.id).every((l) => _lights.contains(l.id)) &&
                        home.lightsIn(room.id).isNotEmpty,
                    onSelected: (v) => toggle(home.lightsIn(room.id).map((l) => l.id), v),
                  ),
                for (final l in home.lights)
                  FilterChip(
                    label: Text(l.name),
                    selected: _lights.contains(l.id),
                    onSelected: (v) => toggle([l.id], v),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _lights.isEmpty ? null : () => Navigator.pop(context, _lights),
                child: const Text('Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
