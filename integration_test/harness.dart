import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';
import 'package:lumen/app.dart';
import 'package:lumen/emulator/bridge_emulator.dart';
import 'package:lumen/emulator/bridge_server.dart';
import 'package:lumen/emulator/nsd.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/music/music_sync.dart';
import 'package:lumen/plugins/music_sync_plugin.dart';
import 'package:lumen/plugins/plugin_manager.dart';
import 'package:lumen/sim/simulated_audio.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/sim/simulated_bridge_platform.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/emulator_store.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/state/music_store.dart';
import 'package:lumen/state/plugin_store.dart';
import 'package:lumen/transport/bridge/lan_bridge_discovery.dart';
import 'package:integration_test/integration_test.dart';

/// Under `flutter test` the suites run with fake time in the test binding;
/// on a device they run with the integration test binding in real time.
void initE2eBinding() {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    TestWidgetsFlutterBinding.ensureInitialized();
  } else {
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  }
}

/// An end-to-end test with a fresh [World]. Afterwards the app is unmounted
/// and pending timers (scans, snack bars, animations) are drained.
@isTestGroup
void e2e(String description, Future<void> Function(WidgetTester tester, World world) body) {
  testWidgets(description, (tester) async {
    final world = World();
    try {
      await body(tester, world);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      world.end();
      await tester.pump(const Duration(minutes: 1));
      world.logDir.deleteSync(recursive: true);
    }
  });
}

/// The whole app wired to a simulated Bluetooth stack and bridge. Tests drive
/// the real widget tree and assert on what the simulated hardware received.
class World {
  World()
    : central = SimulatedBleCentral(scanDelay: const Duration(milliseconds: 300)),
      bridge = SimulatedBridge(id: '001788fffe00beef', name: 'Hallway bridge'),
      store = MemoryHomeStore(),
      emulatorStore = MemoryEmulatorStore(),
      logDir = Directory.systemTemp.createTempSync('lumen-e2e-log');

  final SimulatedBleCentral central;
  final SimulatedBridge bridge;
  final MemoryHomeStore store;
  final MemoryEmulatorStore emulatorStore;

  /// Where the app writes its log; each launch opens a new logger on it.
  final Directory logDir;
  late Logger log;
  late HomeController home;

  /// Launches with a log kept in memory only, without [logDir].
  bool memoryLog = false;

  /// Launches as the demo build does.
  bool demo = false;

  /// Android's mDNS browse; none, as off Android, when null.
  MdnsBrowse? androidMdns;

  /// Builds the emulator's server; the in-process one when null.
  EmulatorServerFactory? emulatorServer;

  /// The phone acting as a Hue Bridge, with an in-process server.
  late BridgeEmulator emulator;
  BridgeEmulator? _emulator;

  /// The Android background service, simulated.
  final background = SimulatedBridgeBackground();

  /// Android's mDNS responder; none unless a test gives one.
  SystemMdns nsd = const NoSystemMdns();

  /// The microphone and the phone's sound, playing a 120 BPM click track.
  final audio = SimulatedAudioInput();
  final musicStore = MemoryMusicStore();
  final pluginStore = MemoryPluginStore();

  /// The plugins of the last launch.
  late PluginManager plugins;
  PluginManager? _plugins;

  /// Music sync of the last launch; its plugin must be on.
  MusicSync get music => plugins.plugin<MusicSyncPlugin>()!.music!;

  /// Stops the bridge and the plugins of the last launch, as when the app ends.
  void end() {
    _emulator?.dispose();
    _plugins?.dispose();
  }

  SimulatedHueBulb bulb(String id, {String name = 'Hue bulb', String model = 'LCA006', bool pairingMode = true}) =>
      central.addBulb(SimulatedHueBulb(id: id, name: name, model: model, pairingMode: pairingMode));

  /// Starts (or restarts) the app on this world's store.
  Future<void> launch(WidgetTester tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      // A typical Android phone: 412 x 915 logical pixels.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2625 / 1000;
      addTearDown(tester.view.reset);
    }
    log = memoryLog ? Logger.memory() : Logger(directory: logDir);
    home = HomeController(
      AppServices.simulated(
        central: central,
        bridge: bridge,
        store: store,
        demo: demo,
        emulatorStore: emulatorStore,
        emulatorServer: emulatorServer,
        androidMdns: androidMdns,
        background: background,
        nsd: nsd,
        audio: audio,
        musicStore: musicStore,
        pluginStore: pluginStore,
        log: log,
      ),
    );
    final previous = _emulator;
    final previousPlugins = _plugins;
    plugins = _plugins = PluginManager.standard(home);
    emulator = _emulator = BridgeEmulator(home, extensions: plugins.bridge);
    await tester.pumpWidget(HueApp(key: ObjectKey(home), home: home, emulator: emulator, plugins: plugins));
    // The app that ran before is gone, as when the process restarts.
    previous?.dispose();
    previousPlugins?.dispose();
    await tester.pumpUntil(() => home.loaded && emulator.loaded && plugins.loaded);
    await tester.pump(const Duration(milliseconds: 300));
  }
}

extension AddThroughUi on World {
  /// Adds a simulated bulb the way a user would: Add light, tap it in the
  /// scan list, back on Home.
  Future<void> addBulbThroughUi(WidgetTester tester, String name) async {
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text(name));
    await tester.tapAndSettle(find.text(name));
    await tester.pumpUntilFound(tileOf(name));
  }
}

extension Drive on WidgetTester {
  /// Pumps frames until [condition] holds, so the same test runs under fake
  /// time in `flutter test` and in real time on a device.
  Future<void> pumpUntil(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
    var waited = Duration.zero;
    const step = Duration(milliseconds: 50);
    while (!condition()) {
      if (waited > timeout) throw TestFailure('condition not met within $timeout');
      await pump(step);
      waited += step;
    }
  }

  Future<void> pumpUntilFound(Finder finder, {Duration timeout = const Duration(seconds: 10)}) async {
    try {
      await pumpUntil(() => any(finder), timeout: timeout);
    } on TestFailure {
      throw TestFailure('not found within $timeout: $finder');
    }
    // Let route transitions and implicit animations finish before acting.
    await settle(const Duration(milliseconds: 500));
  }

  Future<void> pumpUntilGone(Finder finder, {Duration timeout = const Duration(seconds: 10)}) =>
      pumpUntil(() => !any(finder), timeout: timeout);

  Future<void> tapAndSettle(Finder finder) async {
    // Centre the widget in its scroll view where possible, so a tall tile at
    // the end of a list is not left under the navigation bar.
    final target = element(finder);
    if (Scrollable.maybeOf(target) != null) {
      await Scrollable.ensureVisible(target, alignment: 0.5);
      await pump();
    }
    await tap(finder);
    await pump(const Duration(milliseconds: 50));
    await settle(const Duration(milliseconds: 600));
  }

  Future<void> settle(Duration total) async {
    const step = Duration(milliseconds: 50);
    for (var t = Duration.zero; t < total; t += step) {
      await pump(step);
    }
  }
}

Finder tileOf(String name) => find.ancestor(of: find.text(name), matching: find.byKey(const ValueKey('light-tile')));

Finder powerSwitchOf(String name) => find.descendant(of: tileOf(name), matching: find.byType(Switch));

abstract final class SimulatedBridgeLightFactory {
  static SimulatedBridgeLight sofa() => SimulatedBridgeLight(name: 'Sofa');
}
