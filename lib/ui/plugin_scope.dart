// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/widgets.dart';

import '../plugins/plugin_manager.dart';

/// Hands the [PluginManager] down the tree and rebuilds dependents when a
/// plugin is switched on or off.
class PluginScope extends InheritedNotifier<PluginManager> {
  const PluginScope({super.key, required PluginManager plugins, required super.child}) : super(notifier: plugins);

  /// The plugins, or null where the app was built without them.
  static PluginManager? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PluginScope>()?.notifier;
}
