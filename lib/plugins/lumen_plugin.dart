// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/widgets.dart';

import '../emulator/bridge_extensions.dart';
import '../state/home_controller.dart';

export '../emulator/bridge_extensions.dart' show ExtensionHandler, ExtensionRequest;

/// A feature that can be switched off as a whole in Settings, Plugins.
///
/// While on, a plugin is attached to the home, its widgets appear where the
/// app asks for them, and its own API is served on the emulated Hue Bridge
/// under its [id]. Switched off, it is detached and leaves nothing behind:
/// it puts back any lights it changed.
abstract class LumenPlugin {
  /// Kebab-case, unique: the key of its on/off setting and its name on the
  /// bridge, as in `/__plugins__/music-sync`.
  String get id;

  String get name;

  /// One sentence for Settings.
  String get description;

  IconData get icon;

  /// Experimental plugins may change or go away; Settings says so.
  bool get experimental => false;

  /// Whether the plugin is on until the user decides.
  bool get enabledByDefault => true;

  /// Starts the plugin.
  Future<void> attach(HomeController home);

  /// Stops it and puts back what it changed.
  Future<void> detach();

  /// Its API on the emulated bridge by semantic version (`1.0.0`), served
  /// under `/__plugins__/<id>/v<version>/` while it is on. Handlers are
  /// looked up per request, so they may use state that [attach] made.
  Map<String, ExtensionHandler> get bridgeApi => const {};

  /// Wraps the app, for example to hand the plugin's state down the tree.
  /// Called whether the plugin is on or off, so the tree keeps its shape
  /// and the app keeps its state when the plugin is switched.
  Widget wrap(Widget child) => child;

  /// Buttons for Home's app bar while it is on.
  List<Widget> homeActions(BuildContext context) => const [];

  /// Tiles shown under its switch in Settings while it is on.
  List<Widget> settingsEntries(BuildContext context) => const [];
}
