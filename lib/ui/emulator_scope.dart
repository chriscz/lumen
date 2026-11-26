// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/widgets.dart';

import '../emulator/bridge_emulator.dart';

/// Hands the [BridgeEmulator] down the tree and rebuilds dependents when it
/// changes.
class EmulatorScope extends InheritedNotifier<BridgeEmulator> {
  const EmulatorScope({super.key, required BridgeEmulator emulator, required super.child}) : super(notifier: emulator);

  /// The emulator, or null where the app was built without one.
  static BridgeEmulator? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EmulatorScope>()?.notifier;
}
