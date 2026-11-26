// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/home.dart';
import 'profile_swatch.dart';

/// A sheet of profiles to apply to one light or one linked cluster.
Future<void> showProfilePicker(
  BuildContext context, {
  required String title,
  required List<Profile> profiles,
  required ValueChanged<Profile> onPick,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
      child: ListView(
        key: const ValueKey('profile-picker'),
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          if (profiles.isEmpty) const ListTile(title: Text('No profiles yet. Make one in Profiles.')),
          for (final p in profiles)
            ListTile(
              leading: ProfileSwatch(profile: p, size: 36),
              title: Text(p.name),
              subtitle: Text(p.isPreset ? 'Preset' : 'Scene'),
              onTap: () {
                HapticFeedback.selectionClick();
                Navigator.of(context).pop();
                onPick(p);
              },
            ),
        ],
      ),
    ),
  ),
);
