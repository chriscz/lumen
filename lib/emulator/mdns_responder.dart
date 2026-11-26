// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'bridge_api.dart';
import 'dns_message.dart';
import 'emulator_settings.dart';

/// Opens a datagram socket; [RawDatagramSocket.bind] unless a test stands in.
typedef DatagramBinder = Future<RawDatagramSocket> Function(
  dynamic host,
  int port, {
  bool reuseAddress,
  bool reusePort,
  int ttl,
});

/// Advertises the emulated bridge as `_hue._tcp.local` over multicast DNS,
/// the way newer Hue clients look for a bridge (RFC 6762, RFC 6763). See
/// docs/protocol.md.
class MdnsResponder {
  MdnsResponder({
    required this.instance,
    required this.host,
    required this.httpPort,
    required this.address,
    required this.txt,
    this.port = mdnsPort,
    InternetAddress? bindAddress,
    this.multicastGroup = mdnsGroup,
    (InternetAddress, int)? announceTo,
    this.announceGap = const Duration(seconds: 1),
    this.reannounceEvery = const Duration(minutes: 20),
    bool Function()? active,
    this.reopenDelay = const Duration(seconds: 5),
    this.bind = RawDatagramSocket.bind,
  }) : bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       announceTo = announceTo ?? (multicastGroup == null ? null : (InternetAddress(multicastGroup), mdnsPort)),
       _active = active ?? (() => true);

  /// The responder for [settings]' bridge, serving HTTP on [httpPort] at
  /// [address].
  factory MdnsResponder.forBridge(
    EmulatorSettings settings, {
    required int httpPort,
    required String address,
    int port = mdnsPort,
    InternetAddress? bindAddress,
    String? multicastGroup = mdnsGroup,
    (InternetAddress, int)? announceTo,
    Duration announceGap = const Duration(seconds: 1),
    bool Function()? active,
    Duration reopenDelay = const Duration(seconds: 5),
    DatagramBinder bind = RawDatagramSocket.bind,
  }) {
    final id = settings.bridgeId;
    final suffix = id.substring(id.length - 6);
    var hostLabel = settings.name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    hostLabel = hostLabel.replaceAll(RegExp(r'^-+|-+$'), '');
    if (hostLabel.isEmpty) hostLabel = 'lumen';
    return MdnsResponder(
      instance: '${label(settings)}.$service',
      host: '$hostLabel-${suffix.toLowerCase()}.local',
      httpPort: httpPort,
      address: address,
      txt: [for (final MapEntry(:key, :value) in txtFor(settings).entries) '$key=$value'],
      port: port,
      bindAddress: bindAddress,
      multicastGroup: multicastGroup,
      announceTo: announceTo,
      announceGap: announceGap,
      active: active,
      reopenDelay: reopenDelay,
      bind: bind,
    );
  }

  /// The TXT keys a Hue bridge announces: its id in lower case and model.
  static Map<String, String> txtFor(EmulatorSettings settings) => {
    'bridgeid': settings.bridgeId.toLowerCase(),
    'modelid': BridgeApi.modelId,
  };

  /// The instance label: the bridge's name and the last six characters of
  /// its id, such as `Lumen-DDEEFF`. Dots would split the label, so they
  /// become dashes.
  static String label(EmulatorSettings settings) {
    final name = settings.name.replaceAll('.', '-').trim();
    final id = settings.bridgeId;
    return '${name.isEmpty ? 'Lumen' : name}-${id.substring(id.length - 6)}';
  }

  static const mdnsGroup = '224.0.0.251';
  static const mdnsPort = 5353;
  static const service = '_hue._tcp.local';
  static const services = '_services._dns-sd._udp.local';

  /// RFC 6762 section 10: 120 s for records naming a host, 75 min otherwise.
  static const hostTtl = 120;
  static const otherTtl = 4500;

  /// Legacy unicast replies carry at most this TTL (RFC 6762 section 6.7).
  static const legacyTtl = 10;

  /// The full instance name, such as `Lumen-DDEEFF._hue._tcp.local`.
  final String instance;

  /// The host the SRV record points at, such as `lumen-ddeeff.local`.
  final String host;
  final int httpPort;

  /// The phone's LAN IPv4, for the A record.
  final String address;
  final List<String> txt;

  /// The UDP port to listen on; 0 picks a free one (tests).
  final int port;
  final InternetAddress bindAddress;

  /// The group to join; null answers unicast queries only (tests).
  final String? multicastGroup;

  /// Where announcements, goodbyes and multicast replies go; null sends none.
  final (InternetAddress, int)? announceTo;
  final Duration announceGap;
  final Duration reannounceEvery;
  final bool Function() _active;

  /// How long to wait before opening a new socket when the old one failed.
  final Duration reopenDelay;

  /// Opens the socket; tests stand in for [RawDatagramSocket.bind].
  final DatagramBinder bind;

  RawDatagramSocket? _socket;
  Timer? _timer;
  Timer? _reopen;
  bool _announced = false;

  int? get boundPort => _socket?.port;

  DnsRecord get _ptr => DnsRecord(service, ttl: otherTtl, data: PtrData(instance));
  DnsRecord get _srv => DnsRecord(
    instance,
    ttl: hostTtl,
    cacheFlush: true,
    data: SrvData(port: httpPort, target: host),
  );
  DnsRecord get _txt => DnsRecord(instance, ttl: otherTtl, cacheFlush: true, data: TxtData(txt));
  DnsRecord get _a => DnsRecord(host, ttl: hostTtl, cacheFlush: true, data: AData(address));

  List<DnsRecord> get _all => [_ptr, _srv, _txt, _a];

  /// The reply to [query], or null when it asks nothing this responder
  /// knows or the asker already holds every answer. A [legacy] asker (one
  /// not on port 5353) gets its id and questions back, short TTLs and no
  /// cache-flush bits.
  DnsMessage? respond(DnsMessage query, {required bool legacy}) {
    if (query.isResponse) return null;
    final answers = <DnsRecord>[];
    final additionals = <DnsRecord>[];
    void add(List<DnsRecord> list, DnsRecord r) {
      if (![...answers, ...additionals].contains(r)) list.add(r);
    }

    bool wants(DnsQuestion q, int type) => q.type == type || q.type == DnsType.any;
    for (final q in query.questions) {
      if (dnsNamesEqual(q.name, service) && wants(q, DnsType.ptr)) {
        add(answers, _ptr);
      } else if (dnsNamesEqual(q.name, services) && wants(q, DnsType.ptr)) {
        add(answers, DnsRecord(services, ttl: otherTtl, data: const PtrData(service)));
      } else if (dnsNamesEqual(q.name, instance)) {
        if (wants(q, DnsType.srv)) add(answers, _srv);
        if (wants(q, DnsType.txt)) add(answers, _txt);
      } else if (dnsNamesEqual(q.name, host) && wants(q, DnsType.a)) {
        add(answers, _a);
      }
    }
    // Known-answer suppression (RFC 6762 section 7.1).
    answers.removeWhere(
      (r) => query.answers.any((k) => dnsNamesEqual(k.name, r.name) && k.data == r.data && k.ttl * 2 >= r.ttl),
    );
    if (answers.isEmpty) return null;
    // RFC 6763 section 12: the records a client needs next.
    if (answers.any((r) => r.data == PtrData(instance))) {
      add(additionals, _srv);
      add(additionals, _txt);
    }
    if (answers.any((r) => r.type == DnsType.srv) || additionals.any((r) => r.type == DnsType.srv)) {
      add(additionals, _a);
    }
    if (!legacy) return DnsMessage(isResponse: true, answers: answers, additionals: additionals);
    DnsRecord short(DnsRecord r) => r.withTtl(r.ttl < legacyTtl ? r.ttl : legacyTtl, cacheFlush: false);
    return DnsMessage(
      id: query.id,
      isResponse: true,
      questions: query.questions,
      answers: answers.map(short).toList(),
      additionals: additionals.map(short).toList(),
    );
  }

  /// Every record, in one unsolicited response.
  DnsMessage announcement() => DnsMessage(isResponse: true, answers: _all);

  /// Every record with TTL 0, telling caches to drop them.
  DnsMessage goodbyeMessage() => DnsMessage(isResponse: true, answers: [for (final r in _all) r.withTtl(0)]);

  Future<void> start() async {
    if (_socket != null) return;
    _reopen?.cancel();
    RawDatagramSocket socket;
    try {
      socket = await bind(bindAddress, port, reuseAddress: true, reusePort: true);
    } on UnsupportedError {
      socket = await bind(bindAddress, port, reuseAddress: true);
    }
    _socket = socket;
    if (multicastGroup case final group?) {
      try {
        socket
          ..multicastHops = 255
          ..joinMulticast(InternetAddress(group));
      } on Object {
        await stop();
        rethrow;
      }
    }
    socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null || !_active()) return;
        final DnsMessage query;
        try {
          query = DnsMessage.decode(datagram.data);
        } on FormatException {
          return;
        }
        final legacy = datagram.port != mdnsPort;
        final reply = respond(query, legacy: legacy);
        if (reply == null) return;
        if (legacy || query.questions.any((q) => q.unicastResponse)) {
          _send(reply, (datagram.address, datagram.port));
        } else {
          _send(reply, announceTo);
        }
      },
      // A datagram that cannot be sent, as when the network goes away, is
      // reported here rather than thrown by send, and dart:io then closes
      // the socket. A new one takes over after [reopenDelay].
      onError: (Object e) {
        debugPrint('mDNS socket error: $e');
        if (!identical(_socket, socket)) return;
        _socket = null;
        _timer?.cancel();
        _reopen = Timer(reopenDelay, () async {
          try {
            await start();
          } on Object catch (e) {
            debugPrint('mDNS could not reopen: $e');
          }
        });
      },
    );
    announce();
  }

  /// Announces three times, [announceGap] apart, then every
  /// [reannounceEvery] (RFC 6762 section 8.3). Does nothing while inactive.
  void announce() {
    _timer?.cancel();
    if (_socket == null || !_active()) return;
    var sent = 0;
    void tick() {
      if (_socket == null || !_active()) return;
      _send(announcement(), announceTo);
      _announced = true;
      sent++;
      _timer = Timer(sent < 3 ? announceGap : reannounceEvery, tick);
    }

    tick();
  }

  /// Withdraws the records if they were announced, and stops announcing.
  void goodbye() {
    _timer?.cancel();
    _timer = null;
    if (!_announced) return;
    _send(goodbyeMessage(), announceTo);
    _announced = false;
  }

  Future<void> stop() async {
    _reopen?.cancel();
    goodbye();
    _socket?.close();
    _socket = null;
  }

  void _send(DnsMessage message, (InternetAddress, int)? to) {
    final socket = _socket;
    if (socket == null || to == null) return;
    socket.send(message.encode(), to.$1, to.$2);
  }
}
