// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import '../domain/light.dart';
import '../emulator/bridge_server.dart';
import '../emulator/bridge_background.dart';
import '../emulator/multicast_lock.dart';
import '../emulator/nsd.dart';
import '../log/logger.dart';
import '../state/app_services.dart';
import '../state/music_store.dart';
import '../state/plugin_store.dart';
import '../state/emulator_store.dart';
import '../state/home_store.dart';
import 'simulated_ble.dart';
import 'simulated_bridge.dart';

/// A small simulated home for trying the app without hardware.
abstract final class Demo {
  /// The emulated Hue Bridge is real in demo mode: other apps can pair with
  /// the phone and control the simulated lights. The bridge's link button is
  /// pressed every [linkButtonEvery].
  static AppServices services({
    required HomeStore store,
    EmulatorStore? emulatorStore,
    MusicStore? musicStore,
    PluginStore? pluginStore,
    Logger? log,
    Duration linkButtonEvery = const Duration(seconds: 3),
  }) {
    final central = SimulatedBleCentral(latency: const Duration(milliseconds: 60))
      ..addBulb(SimulatedHueBulb(id: 'c4:2c:00:00:00:01', name: 'Desk lamp'))
      ..addBulb(SimulatedHueBulb(id: 'c4:2c:00:00:00:02', name: 'Bedside', model: 'LTA001'))
      ..addBulb(
        SimulatedHueBulb(
          id: 'c4:2c:00:00:00:03',
          name: 'Hallway',
          model: 'LWA001',
          state: const LightState(on: true, brightness: 180),
        ),
      );
    final bridge = SimulatedBridge(name: 'Demo bridge', latency: const Duration(milliseconds: 80))
      ..addLight(
        SimulatedBridgeLight(
          name: 'Sofa',
          state: const LightState(on: true, brightness: 200, color: XyColor(0.55, 0.38)),
        ),
      )
      ..addLight(SimulatedBridgeLight(name: 'Kitchen', type: 'Color temperature light'))
      ..addLight(
        SimulatedBridgeLight(
          name: 'Lightstrip',
          state: const LightState(on: true, brightness: 120, color: XyColor(0.17, 0.12)),
        ),
      );
    // Somebody presses the link button shortly after pairing starts.
    Timer.periodic(linkButtonEvery, (_) => bridge.pressLinkButton());
    return AppServices.simulated(
      central: central,
      bridge: bridge,
      store: store,
      demo: true,
      emulatorStore: emulatorStore,
      emulatorServer: BridgeServer.create,
      multicast: const PlatformMulticastLock(),
      background: const PlatformBridgeBackground(),
      nsd: const PlatformNsd(),
      musicStore: musicStore,
      pluginStore: pluginStore,
      log: log,
    );
  }
}
