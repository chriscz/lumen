// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/discovery_settings.dart';
import 'package:lumen/domain/home.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/lan_bridge_discovery.dart';

void main() {
  late MemoryHomeStore store;
  late SimulatedBridge bridge;
  late List<String> probed;
  MdnsBrowse? android;

  HomeController build() => HomeController(
    AppServices(
      central: SimulatedBleCentral(),
      bridgeClient: (host) => throw UnimplementedError(),
      discovery: LanBridgeDiscovery(
        probe: (host, port) async {
          probed.add('$host:$port');
          return host == '192.168.1.2' ? ProbeBridge(id: bridge.id, name: bridge.name) : const ProbeAbsent();
        },
        mdns: () => Stream.value(const BridgeCandidate(host: '192.168.1.3', port: 80)),
        ssdp: () => const Stream.empty(),
        localAddresses: () async => const [],
        androidMdns: android,
      ),
      store: store,
    ),
  );

  setUp(() {
    store = MemoryHomeStore();
    bridge = SimulatedBridge();
    probed = [];
    android = null;
  });

  test('every method is on by default, and the search tries the saved bridges first', () async {
    await store.save(
      HomeSnapshot(
        bridges: [BridgeAccount(id: bridge.id, name: 'Hall', host: '192.168.1.2', appKey: 'k')],
      ),
    );
    final home = build();
    await home.load();
    expect(home.discoverySettings.enabled, DiscoveryStage.values.toSet());
    final events = await home.discoverBridges().toList();
    expect(events.whereType<StageStarted>().map((e) => e.stage), DiscoveryStage.values);
    expect(events.whereType<BridgeFound>().single.bridge.stage, DiscoveryStage.known);
    expect(probed.first, '192.168.1.2:80');
  });

  test('switching methods off persists, and the search skips them', () async {
    final home = build();
    await home.load();
    var notified = 0;
    home.addListener(() => notified++);
    await home.setDiscoveryStage(DiscoveryStage.ssdp, false);
    await home.setDiscoveryStage(DiscoveryStage.sweep, false);
    expect(notified, 2);
    expect((await store.load()).discovery.enabled, {DiscoveryStage.known, DiscoveryStage.mdns});

    final again = build();
    await again.load();
    expect(again.discoverySettings.summary, '2 of 4 methods on');
    final stages = await again.discoverBridges().where((e) => e is StageStarted).toList();
    expect(stages.map((e) => (e as StageStarted).stage), [DiscoveryStage.known, DiscoveryStage.mdns]);
  });

  test('without an Android browser the built-in mDNS query is used and no choice is offered', () async {
    final home = build();
    await home.load();
    expect(home.hasAndroidMdns, isFalse);
    expect(home.mdnsImplementation, MdnsImplementation.builtIn);
  });

  test('with an Android browser it is the default, and the choice persists', () async {
    final asked = <Duration>[];
    android = (window) async {
      asked.add(window);
      return const [];
    };
    final home = build();
    await home.load();
    expect(home.hasAndroidMdns, isTrue);
    expect(home.mdnsImplementation, MdnsImplementation.android);
    final first = await home.discoverBridges().firstWhere((e) => e is StageStarted && e.mdns != null) as StageStarted;
    expect(first.mdns, MdnsImplementation.android);

    await home.setMdnsImplementation(MdnsImplementation.builtIn);
    expect((await store.load()).discovery.mdns, MdnsImplementation.builtIn);
    final again = build();
    await again.load();
    expect(again.mdnsImplementation, MdnsImplementation.builtIn);
    final events = await again.discoverBridges().toList();
    expect(events.whereType<StageStarted>().firstWhere((e) => e.mdns != null).mdns, MdnsImplementation.builtIn);
    expect(asked, hasLength(1), reason: 'the second search used the built-in query');
  });

  test('the home keeps the discovery settings through JSON', () {
    final snapshot = HomeSnapshot(discovery: const DiscoverySettings().withStage(DiscoveryStage.known, false));
    final back = HomeSnapshot.fromJson(snapshot.toJson());
    expect(back.discovery.off, {DiscoveryStage.known});
    expect(HomeSnapshot.fromJson(const {}).discovery.enabled, DiscoveryStage.values.toSet());
  });
}
