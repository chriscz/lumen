// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../home_scope.dart';
import 'prompts.dart';

/// Asks how long to fade over, then hands the fade to the lights.
Future<void> showSleepFade(BuildContext context, List<String> lightIds) async {
  final home = HomeScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  const choices = {
    '5 minutes': Duration(minutes: 5),
    '15 minutes': Duration(minutes: 15),
    '30 minutes': Duration(minutes: 30),
    '1 hour': Duration(hours: 1),
  };
  final over = await showModalBottomSheet<Duration>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Dim slowly to off. The lights run the fade themselves, so you can close the app.'),
          ),
          for (final MapEntry(:key, :value) in choices.entries)
            ListTile(
              leading: const Icon(Icons.bedtime_outlined),
              title: Text(key),
              onTap: () => Navigator.pop(context, value),
            ),
        ],
      ),
    ),
  );
  if (over == null) return;
  await home.fadeOff(lightIds, over);
  messenger.show('Fading off over ${over.inMinutes} minutes');
}
