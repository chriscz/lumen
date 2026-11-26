// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

/// The channels this plugin answers. The app's Dart side, with its tests and
/// fakes, is in the app: lib/emulator/bridge_background.dart, nsd.dart and
/// nsd_bridge_browser.dart.
abstract final class LumenBridgeServiceChannels {
  /// run, stop, requestNotifications, openBatterySettings.
  static const service = 'lumen/bridge_service';

  /// register, unregister, browse.
  static const nsd = 'lumen/nsd';
}
