// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import '../emulator/bridge_background.dart';
import '../emulator/bridge_server.dart';
import '../emulator/multicast_lock.dart';
import '../emulator/nsd.dart';
import '../log/logger.dart';
import '../music/audio_input.dart';
import '../sim/simulated_audio.dart';
import '../sim/simulated_ble.dart';
import '../sim/simulated_bridge.dart';
import '../transport/ble/ble_central.dart';
import '../transport/bridge/hue_bridge_client.dart';
import '../transport/bridge/lan_bridge_discovery.dart';
import '../transport/bridge/lan_discovery_sources.dart';
import 'emulator_store.dart';
import 'home_store.dart';
import 'music_store.dart';
import 'plugin_store.dart';

typedef BridgeClientFactory = HueBridgeClient Function(String host);

/// The outside world the app talks to, swapped for simulations in tests and
/// in demo mode.
class AppServices {
  AppServices({
    required this.central,
    required this.bridgeClient,
    LanBridgeDiscovery? discovery,
    required this.store,
    this.demo = false,
    EmulatorStore? emulatorStore,
    EmulatorServerFactory? emulatorServer,
    this.multicast = const NoMulticastLock(),
    this.background = const NoBridgeBackground(),
    this.nsd = const NoSystemMdns(),
    this.audio = const NoAudioInput(),
    MusicStore? musicStore,
    PluginStore? pluginStore,
    Logger? log,
  }) : discovery = discovery ?? _nowhere(),
       musicStore = musicStore ?? MemoryMusicStore(),
       pluginStore = pluginStore ?? MemoryPluginStore(),
       emulatorStore = emulatorStore ?? MemoryEmulatorStore(),
       emulatorServer = emulatorServer ?? BridgeServer.create,
       log = log ?? Logger.memory();

  /// The app's log, shown in Diagnostics.
  final Logger log;

  final BleCentral central;
  final BridgeClientFactory bridgeClient;

  /// Finds bridges on the local network.
  final LanBridgeDiscovery discovery;

  /// A discovery that finds nothing, for services that never look.
  static LanBridgeDiscovery _nowhere() => LanBridgeDiscovery(
    probe: (host, port) async => const ProbeAbsent(),
    mdns: Stream.empty,
    ssdp: Stream.empty,
    localAddresses: () async => const [],
  );
  final HomeStore store;
  final bool demo;

  /// Where the Hue Bridge emulator keeps its settings and paired apps.
  final EmulatorStore emulatorStore;

  /// Builds the emulator's server: real sockets in the app, none in tests.
  final EmulatorServerFactory emulatorServer;
  final MulticastLock multicast;

  /// Keeps the emulated bridge running in the background (Android).
  final BridgeBackground background;

  /// Android's own mDNS responder, for the emulated bridge.
  final SystemMdns nsd;

  /// The microphone and the phone's sound, for music sync.
  final AudioInput audio;

  /// Where music sync keeps its settings.
  final MusicStore musicStore;

  /// Which plugins are switched on.
  final PluginStore pluginStore;

  /// Every bridge host resolves to the one simulated [bridge].
  factory AppServices.simulated({
    SimulatedBleCentral? central,
    SimulatedBridge? bridge,
    HomeStore? store,
    bool demo = false,
    EmulatorStore? emulatorStore,
    EmulatorServerFactory? emulatorServer,
    MulticastLock multicast = const NoMulticastLock(),
    MdnsBrowse? androidMdns,
    BridgeBackground background = const NoBridgeBackground(),
    SystemMdns nsd = const NoSystemMdns(),
    AudioInput? audio,
    MusicStore? musicStore,
    PluginStore? pluginStore,
    Logger? log,
  }) {
    final b = bridge ?? SimulatedBridge();
    final client = b.client();
    final logger = log ?? Logger.memory();
    return AppServices(
      central: central ?? SimulatedBleCentral(),
      bridgeClient: (host) => HueBridgeClient(client, Uri.parse('http://$host'), log: logger),
      discovery: simulatedDiscovery(b, androidMdns: androidMdns, log: logger),
      store: store ?? MemoryHomeStore(),
      demo: demo,
      emulatorStore: emulatorStore,
      emulatorServer: emulatorServer ?? InProcessEmulatorServer.new,
      multicast: multicast,
      background: background,
      nsd: nsd,
      audio: audio ?? SimulatedAudioInput(),
      musicStore: musicStore,
      pluginStore: pluginStore,
      log: logger,
    );
  }

  /// A network with [bridge] at 192.168.1.2 and the phone at 192.168.1.50:
  /// mDNS and SSDP name the bridge after a moment, and the sweep finds it
  /// again among hosts that do not answer.
  static LanBridgeDiscovery simulatedDiscovery(SimulatedBridge bridge, {MdnsBrowse? androidMdns, Logger? log}) {
    const host = '192.168.1.2';
    const answerAfter = Duration(milliseconds: 300);
    Stream<BridgeCandidate> advertise() => Stream.fromFuture(
      Future.delayed(answerAfter, () => BridgeCandidate(host: host, port: 80, bridgeId: bridge.id)),
    );
    return LanBridgeDiscovery(
      probe: (h, port) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (h != host) return const ProbeAbsent();
        return port == 80 ? HttpConfigProbe.read(bridge.handle('GET', '/api/config', '').$2) : const ProbeAlive();
      },
      mdns: advertise,
      ssdp: advertise,
      localAddresses: () async => const ['192.168.1.50'],
      androidMdns: androidMdns,
      log: log,
    );
  }
}
