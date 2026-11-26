// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import '../../domain/discovery_settings.dart';
import '../../log/logger.dart';
import 'bridge_ports.dart';
import 'hue_bridge_client.dart';

export '../../domain/discovery_settings.dart' show DiscoveryStage, MdnsImplementation;

/// Android's mDNS browse for `_hue._tcp`, run for [window]. Injected by the
/// platform; null where there is none.
typedef MdnsBrowse = Future<List<({String host, int port, String? bridgeId})>> Function(Duration window);

/// Asks [host] on [port] for `GET /api/config`.
typedef ConfigProbe = Future<ProbeResult> Function(String host, int port);

/// A place a bridge may be, from one of the sources, not yet verified.
class BridgeCandidate {
  const BridgeCandidate({required this.host, required this.port, this.bridgeId});

  final String host;
  final int port;

  /// The id the source advertised, if any; only [ConfigProbe] confirms it.
  final String? bridgeId;
}

/// A bridge that answered `GET /api/config` as a Hue Bridge.
class FoundBridge {
  const FoundBridge({
    required this.host,
    required this.port,
    required this.id,
    required this.name,
    required this.stage,
  });

  final String host;
  final int port;
  final String id;
  final String name;

  /// The stage that found it.
  final DiscoveryStage stage;

  /// A phone running Lumen as a bridge: a real bridge serves 80 and 443.
  bool get phone => port != 80 && port != 443;

  /// What to pair with: `host:port` for a phone, which [HueBridgeClient]
  /// talks to over plain HTTP, and the bare host for a real bridge.
  String get address => phone ? '$host:$port' : host;
}

/// What a host said to `GET /api/config`.
sealed class ProbeResult {
  const ProbeResult();
}

/// It is a Hue Bridge: the answer has a bridge id and a model id.
class ProbeBridge extends ProbeResult {
  const ProbeBridge({required this.id, required this.name});

  final String id;
  final String name;
}

/// Something is there (it answered, or refused the connection), but not a
/// bridge on this port.
class ProbeAlive extends ProbeResult {
  const ProbeAlive();
}

/// Nothing answered in time.
class ProbeAbsent extends ProbeResult {
  const ProbeAbsent();
}

sealed class DiscoveryEvent {
  const DiscoveryEvent();
}

/// A stage began. A sweep says how many [hosts] it tries on how many
/// [ports]; the mDNS stage says which implementation asks.
class StageStarted extends DiscoveryEvent {
  const StageStarted(this.stage, {this.hosts = 0, this.ports = 0, this.mdns});

  final DiscoveryStage stage;
  final int hosts;
  final int ports;
  final MdnsImplementation? mdns;
}

class BridgeFound extends DiscoveryEvent {
  const BridgeFound(this.bridge);

  final FoundBridge bridge;
}

/// Every stage ran; [bridges] in the order they were found.
class DiscoveryFinished extends DiscoveryEvent {
  const DiscoveryFinished(this.bridges);

  final List<FoundBridge> bridges;
}

/// Finds Hue Bridges, real ones and phones running Lumen, on the local
/// network only: nothing leaves the LAN. The stages run one after another,
/// cheapest first, and every candidate is verified with `GET /api/config`
/// once. See docs/protocol.md.
class LanBridgeDiscovery {
  LanBridgeDiscovery({
    required this.probe,
    required this.mdns,
    required this.ssdp,
    required this.localAddresses,
    this.androidMdns,
    List<int>? ports,
    this.concurrency = 64,
    Logger? log,
  }) : ports = ports ?? BridgePorts.probe,
       log = log ?? Logger.memory();

  /// How long Android's browse runs; it resolves each service on its own,
  /// so it needs longer than the built-in query.
  static const androidWindow = Duration(seconds: 3);

  final ConfigProbe probe;

  /// The built-in mDNS query.
  final Stream<BridgeCandidate> Function() mdns;
  final Stream<BridgeCandidate> Function() ssdp;

  /// The phone's Wi-Fi addresses, whose /24 the sweep scans.
  final Future<List<String>> Function() localAddresses;
  final MdnsBrowse? androidMdns;

  /// The ports the sweep tries on each host, the first on every host.
  final List<int> ports;
  final int concurrency;
  final Logger log;

  bool get hasAndroidMdns => androidMdns != null;

  /// Runs the [stages] that are on, in order. Cancelling the subscription
  /// stops the search.
  Stream<DiscoveryEvent> discover({
    List<String> known = const [],
    Set<DiscoveryStage>? stages,
    MdnsImplementation mdns = MdnsImplementation.builtIn,
  }) {
    final run = _Run(this, stages ?? DiscoveryStage.values.toSet(), mdns);
    final out = StreamController<DiscoveryEvent>();
    run.emit = out.add;
    out
      ..onListen = (() => run.go(known).whenComplete(out.close))
      ..onCancel = run.cancel;
    return out.stream;
  }

  /// Every host of the /24 of each address, without the network and
  /// broadcast addresses.
  static List<String> subnetHosts(List<String> addresses) {
    final prefixes = <String>{};
    for (final a in addresses) {
      final parts = a.split('.');
      if (parts.length == 4) prefixes.add(parts.take(3).join('.'));
    }
    return [
      for (final p in prefixes)
        for (var i = 1; i < 255; i++) '$p.$i',
    ];
  }

  /// A saved address as host and port: port 80 when none is given.
  static BridgeCandidate? knownCandidate(String address) {
    final Uri base;
    try {
      base = HueBridgeClient.baseFor(address);
    } on FormatException {
      return null;
    }
    if (base.host.isEmpty) return null;
    return BridgeCandidate(host: base.host, port: base.scheme == 'http' ? base.port : 80);
  }
}

class _Run {
  _Run(this.d, this.stages, this.mdns);

  final LanBridgeDiscovery d;
  final Set<DiscoveryStage> stages;
  final MdnsImplementation mdns;
  late void Function(DiscoveryEvent) emit;

  final Map<String, FoundBridge> _found = {};
  final Set<String> _tried = {};
  bool _cancelled = false;
  final List<void Function()> _onCancel = [];

  void cancel() {
    _cancelled = true;
    for (final f in [..._onCancel]) {
      f();
    }
  }

  void _emit(DiscoveryEvent e) {
    if (!_cancelled) emit(e);
  }

  /// Probes [c] unless it was tried or its bridge is known. Null when
  /// skipped.
  Future<ProbeResult?> _verify(BridgeCandidate c, DiscoveryStage stage) async {
    if (_cancelled) return null;
    if (c.bridgeId case final id? when _found.containsKey(id.toLowerCase())) return null;
    if (!_tried.add('${c.host}:${c.port}')) return null;
    final result = await d.probe(c.host, c.port);
    if (result case ProbeBridge(:final id, :final name) when !_found.containsKey(id.toLowerCase())) {
      final bridge = FoundBridge(host: c.host, port: c.port, id: id.toLowerCase(), name: name, stage: stage);
      _found[bridge.id] = bridge;
      d.log.info(LogTag.bridge, 'found bridge ${bridge.id} at ${bridge.address} by ${stage.name}');
      _emit(BridgeFound(bridge));
    }
    return result;
  }

  Future<void> go(List<String> known) async {
    for (final stage in DiscoveryStage.values) {
      if (_cancelled) return;
      if (!stages.contains(stage)) continue;
      try {
        switch (stage) {
          case DiscoveryStage.known:
            _emit(const StageStarted(DiscoveryStage.known));
            await Future.wait([
              for (final c in known.map(LanBridgeDiscovery.knownCandidate))
                if (c != null) _verify(c, stage),
            ]);
          case DiscoveryStage.mdns:
            final android = mdns == MdnsImplementation.android && d.androidMdns != null;
            if (mdns == MdnsImplementation.android && !android) {
              d.log.info(LogTag.bridge, 'no Android mDNS browser, using the built-in query');
            }
            _emit(
              StageStarted(
                DiscoveryStage.mdns,
                mdns: android ? MdnsImplementation.android : MdnsImplementation.builtIn,
              ),
            );
            await _drain(android ? _browse() : d.mdns(), stage);
          case DiscoveryStage.ssdp:
            _emit(const StageStarted(DiscoveryStage.ssdp));
            await _drain(d.ssdp(), stage);
          case DiscoveryStage.sweep:
            await _sweep();
        }
      } on Object catch (e) {
        d.log.warning(LogTag.bridge, 'discovery stage ${stage.name} failed: $e');
      }
    }
    _emit(DiscoveryFinished(_found.values.toList()));
  }

  Stream<BridgeCandidate> _browse() async* {
    final found = await d.androidMdns!(LanBridgeDiscovery.androidWindow);
    for (final f in found) {
      yield BridgeCandidate(host: f.host, port: f.port, bridgeId: f.bridgeId);
    }
  }

  /// Verifies each candidate of [source] as it arrives, until it ends or
  /// the search is cancelled.
  Future<void> _drain(Stream<BridgeCandidate> source, DiscoveryStage stage) async {
    final pending = <Future<void>>[];
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final sub = source.listen(
      (c) => pending.add(_verify(c, stage)),
      onError: (Object e) {
        d.log.warning(LogTag.bridge, '${stage.name} failed: $e');
        finish();
      },
      onDone: finish,
      cancelOnError: true,
    );
    void stop() {
      sub.cancel();
      finish();
    }

    _onCancel.add(stop);
    await done.future;
    _onCancel.remove(stop);
    await Future.wait(pending);
  }

  Future<void> _sweep() async {
    final List<String> addresses;
    try {
      addresses = await d.localAddresses();
    } on Object catch (e) {
      d.log.warning(LogTag.bridge, 'no local addresses to scan: $e');
      _emit(const StageStarted(DiscoveryStage.sweep));
      return;
    }
    final hosts = LanBridgeDiscovery.subnetHosts(addresses);
    if (_cancelled) return;
    _emit(StageStarted(DiscoveryStage.sweep, hosts: hosts.length, ports: hosts.isEmpty ? 0 : d.ports.length));
    if (hosts.isEmpty) return;
    final first = d.ports.first;
    final alive = <String>{};
    await _pool(hosts, (host) async {
      final r = await _verify(BridgeCandidate(host: host, port: first), DiscoveryStage.sweep);
      if (r is! ProbeAbsent) alive.add(host);
    });
    await _pool([
      for (final host in hosts)
        if (alive.contains(host))
          for (final port in d.ports.skip(1)) BridgeCandidate(host: host, port: port),
    ], (c) => _verify(c, DiscoveryStage.sweep));
  }

  /// Runs [work] on [items], at most [LanBridgeDiscovery.concurrency] at a
  /// time, until done or cancelled.
  Future<void> _pool<T>(List<T> items, Future<void> Function(T) work) async {
    var next = 0;
    Future<void> worker() async {
      while (!_cancelled && next < items.length) {
        await work(items[next++]);
      }
    }

    await Future.wait([for (var i = 0; i < d.concurrency; i++) worker()]);
  }
}
