// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/widgets.dart';

import '../music/music_sync.dart';

/// Hands [MusicSync] down the tree and rebuilds dependents when it changes.
/// It stays in the tree with no music sync while the plugin is off.
class MusicScope extends InheritedNotifier<MusicSync> {
  const MusicScope({super.key, required MusicSync? music, required super.child}) : super(notifier: music);

  /// Music sync, or null while its plugin is off.
  static MusicSync? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<MusicScope>()?.notifier;
}
