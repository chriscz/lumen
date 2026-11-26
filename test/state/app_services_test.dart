// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/bridge_server.dart';
import 'package:lumen/emulator/bridge_background.dart';
import 'package:lumen/emulator/multicast_lock.dart';
import 'package:lumen/emulator/nsd.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/emulator_store.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/lan_bridge_discovery.dart';

void main() {
  test('the plain services default to memory stores, real emulator sockets and no multicast lock', () {
    final services = AppServices(
      central: SimulatedBleCentral(),
      bridgeClient: (host) => throw UnimplementedError(),
      store: MemoryHomeStore(),
    );
    expect(services.demo, isFalse);
    expect(services.emulatorStore, isA<MemoryEmulatorStore>());
    expect(services.emulatorServer, BridgeServer.create);
    expect(services.multicast, isA<NoMulticastLock>());
    expect(services.background, isA<NoBridgeBackground>());
    expect(services.nsd, isA<NoSystemMdns>());
    expect(services.log.directory, isNull, reason: 'a memory log');
  });

  test('the plain services find no bridge unless given a discovery', () async {
    final services = AppServices(
      central: SimulatedBleCentral(),
      bridgeClient: (host) => throw UnimplementedError(),
      store: MemoryHomeStore(),
    );
    expect(services.discovery.hasAndroidMdns, isFalse);
    final events = await services.discovery.discover(known: const ['192.168.1.2']).toList();
    expect(events.last, isA<DiscoveryFinished>().having((e) => e.bridges, 'bridges', isEmpty));
  });

  group('simulated', () {
    test('every bridge host reaches the one simulated bridge', () async {
      final bridge = SimulatedBridge(name: 'Test bridge');
      final services = AppServices.simulated(bridge: bridge);
      for (final host in ['192.168.1.2', '10.0.0.9']) {
        final client = services.bridgeClient(host);
        expect(client.base, Uri.parse('http://$host'));
        expect((await client.config()).name, 'Test bridge');
      }
    });

    test('discovery finds the simulated bridge at a fixed address by mDNS, and nothing else', () async {
      final bridge = SimulatedBridge();
      final events = await AppServices.simulated(bridge: bridge).discovery.discover().toList();
      final found = events.whereType<BridgeFound>().map((e) => e.bridge).toList();
      expect(found.map((b) => (b.id, b.address, b.stage)), [(bridge.id, '192.168.1.2', DiscoveryStage.mdns)]);
      final sweep = events.whereType<StageStarted>().last;
      expect((sweep.stage, sweep.hosts, sweep.ports), (DiscoveryStage.sweep, 254, 11));
    });

    test('the simulated discovery can browse with a given Android mDNS browser', () async {
      final services = AppServices.simulated(androidMdns: (_) async => const []);
      expect(services.discovery.hasAndroidMdns, isTrue);
    });

    test('by default it simulates everything in memory, with an in-process emulator', () {
      final services = AppServices.simulated();
      expect(services.central, isA<SimulatedBleCentral>());
      expect(services.store, isA<MemoryHomeStore>());
      expect(services.emulatorStore, isA<MemoryEmulatorStore>());
      expect(services.emulatorServer, isNot(BridgeServer.create));
      expect(services.demo, isFalse);
    });

    test('the bridge clients log to the services log', () async {
      final services = AppServices.simulated();
      services.log.debugEnabled = true;
      await services.bridgeClient('192.168.1.2').config();
      expect(services.log.entries.map((e) => e.message), contains(startsWith('GET /api/config')));
    });
  });
}
