// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import 'home_scope.dart';

/// A thin bar above every screen while a bridge is offline and the app
/// tries to reach it again. The screen under it keeps its state: the tree
/// is the same with and without the bar.
class ReconnectBar extends StatelessWidget {
  const ReconnectBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final offline = [
      for (final b in home.bridges)
        if (home.offlineBridges.contains(b.id)) b,
    ];
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (offline.isNotEmpty)
          Material(
            key: const ValueKey('reconnect-bar'),
            color: scheme.secondaryContainer,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, media.padding.top + 4, 16, 4),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onSecondaryContainer),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      offline.length == 1
                          ? 'Reconnecting to ${offline.single.name}...'
                          : 'Reconnecting to ${offline.length} bridges...',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSecondaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: MediaQuery(data: offline.isEmpty ? media : media.removePadding(removeTop: true), child: child),
        ),
      ],
    );
  }
}
