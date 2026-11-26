// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/transport/bridge/lan_bridge_discovery.dart';

/// A made-up network: which host:port answers as which bridge, and which
/// hosts exist at all.
class _Network {
  final Map<String, (String, String)> bridges = {};
  final Set<String> alive = {};
  final List<String> probed = [];

  Future<ProbeResult> probe(String host, int port) async {
    probed.add('$host:$port');
    await Future<void>.delayed(Duration.zero);
    if (bridges['$host:$port'] case (final id, final name)) return ProbeBridge(id: id, name: name);
    return alive.contains(host) ? const ProbeAlive() : const ProbeAbsent();
  }
}

String describe(DiscoveryEvent e) => switch (e) {
  StageStarted(:final stage, :final hosts, :final ports, :final mdns) =>
    'start ${stage.name}${hosts > 0 ? ' $hosts x $ports' : ''}${mdns != null ? ' ${mdns.name}' : ''}',
  BridgeFound(:final bridge) => 'found ${bridge.id} at ${bridge.address} by ${bridge.stage.name}',
  DiscoveryFinished(:final bridges) => 'finished ${bridges.length}',
};

void main() {
  late _Network net;
  late Logger log;

  setUp(() {
    net = _Network();
    log = Logger.memory();
  });

  LanBridgeDiscovery build({
    List<BridgeCandidate> mdns = const [],
    List<BridgeCandidate> ssdp = const [],
    List<String> addresses = const [],
    MdnsBrowse? android,
    List<int> ports = const [80, 1818],
  }) => LanBridgeDiscovery(
    probe: net.probe,
    mdns: () => Stream.fromIterable(mdns),
    ssdp: () => Stream.fromIterable(ssdp),
    androidMdns: android,
    localAddresses: () async => addresses,
    ports: ports,
    concurrency: 8,
    log: log,
  );

  test('runs the stages in order and lists each bridge once, as it is verified', () async {
    net.bridges['192.168.1.2:80'] = ('001788fffe000001', 'Hallway');
    net.bridges['192.168.1.9:1818'] = ('aabbccfffe000002', 'Phone');
    net.alive.addAll(['192.168.1.2', '192.168.1.9']);
    final discovery = build(
      mdns: const [
        BridgeCandidate(host: '192.168.1.2', port: 443, bridgeId: '001788FFFE000001'),
        BridgeCandidate(host: '192.168.1.9', port: 1818),
      ],
      ssdp: const [
        BridgeCandidate(host: '192.168.1.2', port: 80, bridgeId: '001788fffe000001'),
        BridgeCandidate(host: '192.168.1.9', port: 1818, bridgeId: 'aabbccfffe000002'),
      ],
      addresses: const ['192.168.1.50'],
    );
    final events = await discovery.discover(known: const ['192.168.1.2']).toList();
    expect(events.map(describe), [
      'start known',
      'found 001788fffe000001 at 192.168.1.2 by known',
      'start mdns builtIn',
      'found aabbccfffe000002 at 192.168.1.9:1818 by mdns',
      'start ssdp',
      'start sweep 254 x 2',
      'finished 2',
    ]);
    final phone = (events.last as DiscoveryFinished).bridges.last;
    expect(phone.phone, isTrue);
    expect(phone.host, '192.168.1.9');
    expect(phone.port, 1818);
    expect(phone.name, 'Phone');
    expect((events.last as DiscoveryFinished).bridges.first.phone, isFalse);
    expect(net.probed.where((p) => p == '192.168.1.2:80'), hasLength(1), reason: 'never verified twice');
    expect(net.probed, isNot(contains('192.168.1.2:443')), reason: 'its id was already found');
    expect(net.probed.where((p) => p == '192.168.1.9:1818'), hasLength(1));
  });

  test('the sweep tries the first port on every host, then the other ports only on hosts that exist', () async {
    net.alive.add('10.0.0.7');
    net.bridges['10.0.0.7:1818'] = ('aabbccfffe000003', 'Kitchen phone');
    final events = await build(addresses: const ['10.0.0.20', '10.0.0.21'])
        .discover(stages: {DiscoveryStage.sweep})
        .toList();
    expect(events.map(describe), [
      'start sweep 254 x 2',
      'found aabbccfffe000003 at 10.0.0.7:1818 by sweep',
      'finished 1',
    ]);
    expect(net.probed.where((p) => p.endsWith(':80')), hasLength(254), reason: 'one /24, swept once');
    expect(net.probed.where((p) => p.endsWith(':1818')), ['10.0.0.7:1818']);
    expect(net.probed, isNot(contains('10.0.0.0:80')));
    expect(net.probed, isNot(contains('10.0.0.255:80')));
  });

  test('a sweep with no Wi-Fi address scans nothing', () async {
    final events = await build().discover(stages: {DiscoveryStage.sweep}).toList();
    expect(events.map(describe), ['start sweep', 'finished 0']);
    expect(net.probed, isEmpty);
  });

  test('a sweep skips what an earlier stage tried, but still uses it to know the host exists', () async {
    net.bridges['10.0.0.7:1818'] = ('aabbccfffe000003', 'Kitchen phone');
    final events = await build(addresses: const ['10.0.0.20'])
        .discover(known: const ['10.0.0.7'], stages: {DiscoveryStage.known, DiscoveryStage.sweep})
        .toList();
    expect(events.map(describe), contains('found aabbccfffe000003 at 10.0.0.7:1818 by sweep'));
    expect(net.probed.where((p) => p == '10.0.0.7:80'), hasLength(1));
  });

  test('stages that are off are skipped and not announced', () async {
    net.bridges['192.168.1.2:80'] = ('001788fffe000001', 'Hallway');
    final discovery = build(ssdp: const [BridgeCandidate(host: '192.168.1.2', port: 80)]);
    final events = await discovery.discover(known: const ['192.168.1.2'], stages: {DiscoveryStage.ssdp}).toList();
    expect(events.map(describe), ['start ssdp', 'found 001788fffe000001 at 192.168.1.2 by ssdp', 'finished 1']);
    expect(await discovery.discover(stages: const {}).map(describe).toList(), ['finished 0']);
  });

  test('known hosts keep their port, and a bad one is skipped', () async {
    net.bridges['192.168.1.9:1919'] = ('aabbccfffe000002', 'Phone');
    final events = await build()
        .discover(known: const ['192.168.1.9:1919', '[::1', ''], stages: {DiscoveryStage.known})
        .toList();
    expect(events.map(describe), ['start known', 'found aabbccfffe000002 at 192.168.1.9:1919 by known', 'finished 1']);
    expect(net.probed, ['192.168.1.9:1919']);
  });

  test('a candidate that is not a bridge is not listed', () async {
    net.alive.add('192.168.1.3');
    final events = await build(mdns: const [BridgeCandidate(host: '192.168.1.3', port: 80)])
        .discover(stages: {DiscoveryStage.mdns})
        .toList();
    expect(events.map(describe), ['start mdns builtIn', 'finished 0']);
  });

  test('Android mDNS is used when asked for and available, and its answers are verified', () async {
    net.bridges['192.168.1.9:1818'] = ('aabbccfffe000002', 'Phone');
    Duration? asked;
    final discovery = build(
      android: (window) async {
        asked = window;
        return [
          (host: '192.168.1.9', port: 1818, bridgeId: 'aabbccfffe000002'),
          (host: '192.168.1.10', port: 1818, bridgeId: null),
        ];
      },
    );
    expect(discovery.hasAndroidMdns, isTrue);
    final events = await discovery.discover(stages: {DiscoveryStage.mdns}, mdns: MdnsImplementation.android).toList();
    expect(events.map(describe), [
      'start mdns android',
      'found aabbccfffe000002 at 192.168.1.9:1818 by mdns',
      'finished 1',
    ]);
    expect(asked, LanBridgeDiscovery.androidWindow);
    expect(net.probed, ['192.168.1.9:1818', '192.168.1.10:1818']);
  });

  test('a failing Android browse is logged and finds nothing', () async {
    final discovery = build(android: (_) async => throw StateError('NSD failed'));
    final events = await discovery.discover(stages: {DiscoveryStage.mdns}, mdns: MdnsImplementation.android).toList();
    expect(events.map(describe), ['start mdns android', 'finished 0']);
    expect(log.entries.map((e) => e.message), contains(contains('NSD failed')));
  });

  test('Android mDNS falls back to the built-in query when no browser is given, and says so', () async {
    net.bridges['192.168.1.2:80'] = ('001788fffe000001', 'Hallway');
    final discovery = build(mdns: const [BridgeCandidate(host: '192.168.1.2', port: 80)]);
    expect(discovery.hasAndroidMdns, isFalse);
    final events = await discovery.discover(stages: {DiscoveryStage.mdns}, mdns: MdnsImplementation.android).toList();
    expect(events.map(describe).first, 'start mdns builtIn');
    expect(events.map(describe), contains('found 001788fffe000001 at 192.168.1.2 by mdns'));
    expect(log.entries.map((e) => e.message), contains(contains('no Android mDNS browser, using the built-in query')));
  });

  test('a source that fails is logged and the search goes on', () async {
    net.bridges['192.168.1.2:80'] = ('001788fffe000001', 'Hallway');
    final discovery = LanBridgeDiscovery(
      probe: net.probe,
      mdns: () => Stream.error(const FormatException('socket closed')),
      ssdp: () => Stream.value(const BridgeCandidate(host: '192.168.1.2', port: 80)),
      localAddresses: () async => throw const FormatException('no interfaces'),
      log: log,
    );
    final events = await discovery.discover().toList();
    expect(events.map(describe), [
      'start known',
      'start mdns builtIn',
      'start ssdp',
      'found 001788fffe000001 at 192.168.1.2 by ssdp',
      'start sweep',
      'finished 1',
    ]);
    final messages = log.entries.map((e) => e.message).join('\n');
    expect(messages, contains('mdns failed'));
    expect(messages, contains('no interfaces'));
  });

  test('a source that cannot start is logged and the next stage runs', () async {
    net.bridges['192.168.1.2:80'] = ('001788fffe000001', 'Hallway');
    final discovery = LanBridgeDiscovery(
      probe: net.probe,
      mdns: () => throw const SocketException('no socket'),
      ssdp: () => Stream.value(const BridgeCandidate(host: '192.168.1.2', port: 80)),
      localAddresses: () async => const [],
      log: log,
    );
    final events = await discovery.discover(stages: {DiscoveryStage.mdns, DiscoveryStage.ssdp}).toList();
    expect(events.map(describe), contains('found 001788fffe000001 at 192.168.1.2 by ssdp'));
    expect(log.entries.map((e) => e.message), contains(contains('discovery stage mdns failed')));
  });

  test('cancelling stops the search before the next stage and between probes', () async {
    net.alive.add('10.0.0.7');
    final mdns = StreamController<BridgeCandidate>();
    final discovery = LanBridgeDiscovery(
      probe: net.probe,
      mdns: () => mdns.stream,
      ssdp: () => fail('ssdp must not start after cancel'),
      localAddresses: () async => fail('the sweep must not start after cancel'),
      log: log,
    );
    final seen = <String>[];
    late StreamSubscription<DiscoveryEvent> sub;
    sub = discovery.discover(known: const ['10.0.0.7']).listen((e) {
      seen.add(describe(e));
      if (e case StageStarted(stage: DiscoveryStage.mdns)) {
        mdns.add(const BridgeCandidate(host: '10.0.0.8', port: 80));
        Future<void>.delayed(const Duration(milliseconds: 10), () async {
          await sub.cancel();
          mdns.add(const BridgeCandidate(host: '10.0.0.9', port: 80));
        });
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(seen, ['start known', 'start mdns builtIn']);
    expect(net.probed, ['10.0.0.7:80', '10.0.0.8:80']);
    expect(mdns.hasListener, isFalse, reason: 'the source is closed');
    await mdns.close();
  });

  test('a found bridge reads its address and kind from its port', () {
    const real = FoundBridge(host: '192.168.1.2', port: 80, id: 'a', name: 'A', stage: DiscoveryStage.ssdp);
    const secure = FoundBridge(host: '192.168.1.2', port: 443, id: 'a', name: 'A', stage: DiscoveryStage.mdns);
    const phone = FoundBridge(host: '192.168.1.9', port: 2020, id: 'b', name: 'B', stage: DiscoveryStage.sweep);
    expect([real.address, secure.address, phone.address], ['192.168.1.2', '192.168.1.2', '192.168.1.9:2020']);
    expect([real.phone, secure.phone, phone.phone], [false, false, true]);
  });
}
