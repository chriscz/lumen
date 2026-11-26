// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'emulator/bridge_background.dart';
import 'emulator/multicast_lock.dart';
import 'emulator/nsd.dart';
import 'emulator/nsd_bridge_browser.dart';
import 'log/app_logging.dart';
import 'log/logger.dart';
import 'music/platform_audio_input.dart';
import 'sim/demo.dart';
import 'state/app_services.dart';
import 'state/emulator_store.dart';
import 'state/home_controller.dart';
import 'state/home_store.dart';
import 'state/music_store.dart';
import 'state/plugin_store.dart';
import 'transport/ble/universal_ble_central.dart';
import 'transport/bridge/hue_bridge_client.dart';
import 'transport/bridge/lan_bridge_discovery.dart';
import 'transport/bridge/lan_discovery_sources.dart';

/// Build with `--dart-define=DEMO=true` to run against simulated lights.
const demoMode = bool.fromEnvironment('DEMO');

void main() => bootstrap(demo: demoMode); // coverage:ignore-line only the platform calls main and tests call bootstrap

/// Starts the app: opens the log, sends uncaught errors to it, builds the
/// services (simulated ones in [demo] mode, unless [services] are given),
/// logs the run header and runs [HueApp] with [run].
void bootstrap({
  required bool demo,
  Future<Logger> Function() openLog = AppLogging.open,
  AppServices Function(Logger log)? services,
  void Function(Widget app) run = runApp,
}) {
  Logger? log;
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      final logger = log = await openLog();
      AppLogging.captureErrors(logger);
      final built = (services ?? (demo ? demoServices : realServices))(logger);
      unawaited(AppLogging.logRunHeader(logger, built.central));
      run(HueApp(home: HomeController(built)));
    },
    (error, stack) {
      final logger = log;
      if (logger == null) {
        debugPrint('Uncaught error before the log opened: $error\n$stack');
      } else {
        AppLogging.zoneError(logger, error, stack);
      }
    },
  );
}

/// Bluetooth bulbs and Hue Bridges for real, with the home kept on the phone.
AppServices realServices(Logger log) => AppServices(
  central: UniversalBleCentral(log: log),
  bridgeClient: (host) => HueBridgeClient.forHost(host, log: log),
  discovery: lanDiscovery(log),
  store: SharedPrefsHomeStore(),
  emulatorStore: SharedPrefsEmulatorStore(),
  multicast: const PlatformMulticastLock(),
  background: const PlatformBridgeBackground(),
  nsd: const PlatformNsd(),
  audio: const PlatformAudioInput(),
  musicStore: SharedPrefsMusicStore(),
  pluginStore: SharedPrefsPluginStore(),
  log: log,
);

/// Bridge discovery on the local network only, with real sockets. On
/// Android, mDNS can also ask through the system's NsdManager.
LanBridgeDiscovery lanDiscovery(Logger log, {bool? android}) => LanBridgeDiscovery(
  probe: HttpConfigProbe().call,
  mdns: MdnsQuery().search,
  androidMdns: (android ?? Platform.isAndroid) ? const NsdBridgeBrowser().browse : null,
  ssdp: SsdpSearch().search,
  localAddresses: localWifiAddresses,
  log: log,
);

/// The simulated lights of [Demo], with the home kept on the phone.
AppServices demoServices(Logger log) =>
    Demo.services(
      store: SharedPrefsHomeStore(),
      emulatorStore: SharedPrefsEmulatorStore(),
      musicStore: SharedPrefsMusicStore(),
      pluginStore: SharedPrefsPluginStore(),
      log: log,
    );
