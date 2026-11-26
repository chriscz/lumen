// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../emulator/dns_message.dart';
import 'lan_bridge_discovery.dart';

/// Sends [message] to each of [targets], each from its own ephemeral
/// socket so one failing target (dart:io closes a socket whose send fails)
/// leaves the others, and streams what [read] makes of each reply until
/// [window] ends.
Stream<BridgeCandidate> _ask(
  List<int> message,
  List<(InternetAddress, int)> targets,
  Duration window,
  List<BridgeCandidate> Function(Datagram) read, {
  required InternetAddress bindAddress,
  bool broadcast = false,
}) {
  late final StreamController<BridgeCandidate> out;
  final sockets = <RawDatagramSocket>[];
  Timer? timer;
  void close() {
    timer?.cancel();
    for (final s in sockets) {
      s.close();
    }
    sockets.clear();
    if (!out.isClosed) out.close();
  }

  out = StreamController(
    onListen: () async {
      for (final (address, port) in targets) {
        final s = await RawDatagramSocket.bind(bindAddress, 0);
        sockets.add(s);
        s
          ..broadcastEnabled = broadcast
          ..listen((_) {
            if (s.receive() case final d?) read(d).forEach(out.add);
          }, onError: (Object _) => s.close())
          ..send(message, address, port);
      }
      timer = Timer(window, close);
    },
    onCancel: close,
  );
  return out.stream;
}

/// A one-shot mDNS query for `_hue._tcp.local` from an ephemeral port: a
/// legacy unicast query (RFC 6762 section 6.7), so responders answer
/// straight back and the phone needs no multicast lock to hear them.
class MdnsQuery {
  MdnsQuery({
    InternetAddress? to,
    this.port = 5353,
    this.window = const Duration(milliseconds: 1500),
    InternetAddress? bindAddress,
  }) : to = to ?? InternetAddress('224.0.0.251'),
       bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  /// Where the ephemeral socket binds; any address in the app.
  final InternetAddress bindAddress;

  static const service = '_hue._tcp.local';

  final InternetAddress to;
  final int port;
  final Duration window;

  static final _random = Random();

  static DnsMessage query(int id) => DnsMessage(id: id, questions: const [DnsQuestion(service, DnsType.ptr)]);

  Stream<BridgeCandidate> search() => _ask(query(_random.nextInt(0x10000)).encode(), [(to, port)], window, (d) {
    try {
      return candidates(DnsMessage.decode(d.data), d.address);
    } on FormatException {
      return const [];
    }
  }, bindAddress: bindAddress);

  /// The bridges a reply names: each instance of the service with its SRV
  /// port, the `bridgeid` of its TXT record and the address of its host,
  /// or the sender when the reply has no A record for it.
  static List<BridgeCandidate> candidates(DnsMessage reply, InternetAddress from) {
    if (!reply.isResponse) return const [];
    final records = [...reply.answers, ...reply.additionals];
    final out = <BridgeCandidate>[];
    for (final r in records) {
      if (r.data case PtrData(name: final instance) when dnsNamesEqual(r.name, service)) {
        DnsData? of(String name, int type) =>
            records.where((x) => x.type == type && dnsNamesEqual(x.name, name)).firstOrNull?.data;
        final srv = of(instance, DnsType.srv);
        if (srv is! SrvData) continue;
        final txt = of(instance, DnsType.txt);
        final id = txt is TxtData
            ? txt.entries.where((e) => e.toLowerCase().startsWith('bridgeid=')).firstOrNull?.substring(9)
            : null;
        final a = of(srv.target, DnsType.a);
        out.add(
          BridgeCandidate(host: a is AData ? a.address : from.address, port: srv.port, bridgeId: id?.toLowerCase()),
        );
      }
    }
    return out;
  }
}

/// An SSDP M-SEARCH sent to the multicast group and to the broadcast
/// address, so a network that filters multicast still answers.
class SsdpSearch {
  SsdpSearch({
    List<(InternetAddress, int)>? targets,
    this.window = const Duration(seconds: 2),
    InternetAddress? bindAddress,
  }) : targets = targets ?? [(InternetAddress('239.255.255.250'), 1900), (InternetAddress('255.255.255.255'), 1900)],
       bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  final InternetAddress bindAddress;

  final List<(InternetAddress, int)> targets;
  final Duration window;

  static const request =
      'M-SEARCH * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:1900\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 1\r\n'
      'ST: ssdp:all\r\n'
      '\r\n';

  Stream<BridgeCandidate> search() => _ask(
    utf8.encode(request),
    targets,
    window,
    (d) {
      final c = parse(utf8.decode(d.data, allowMalformed: true));
      return c == null ? const [] : [c];
    },
    bindAddress: bindAddress,
    broadcast: true,
  );

  /// The bridge a search reply names, from its LOCATION and `hue-bridgeid`
  /// headers. Null for a reply from something that is not a Hue Bridge.
  static BridgeCandidate? parse(String response) {
    final lines = response.split(RegExp(r'\r?\n'));
    if (!lines.first.toUpperCase().startsWith('HTTP/1.1 200')) return null;
    final headers = {
      for (final line in lines.skip(1))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim().toLowerCase(): line.substring(line.indexOf(':') + 1).trim(),
    };
    final id = headers['hue-bridgeid'];
    if (id == null && !(headers['server'] ?? '').contains('IpBridge')) return null;
    final location = Uri.tryParse(headers['location'] ?? '');
    if (location == null || location.host.isEmpty) return null;
    return BridgeCandidate(host: location.host, port: location.port, bridgeId: id?.toLowerCase());
  }
}

/// `GET /api/config` over plain HTTP, or HTTPS on 443 where a real bridge
/// shows a certificate from the Signify CA, accepted for that host only.
class HttpConfigProbe {
  HttpConfigProbe({
    this.connectTimeout = const Duration(milliseconds: 400),
    this.timeout = const Duration(milliseconds: 1500),
  });

  final Duration connectTimeout;
  final Duration timeout;

  static Uri uriFor(String host, int port) =>
      Uri(scheme: port == 443 ? 'https' : 'http', host: host, port: port, path: '/api/config');

  Future<ProbeResult> call(String host, int port) async {
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..badCertificateCallback = (cert, certHost, _) => certHost == host;
    try {
      final request = await client.getUrl(uriFor(host, port));
      final response = await request.close().timeout(timeout);
      final body = await utf8.decodeStream(response.take(64)).timeout(timeout);
      return read(jsonDecode(body));
    } on TimeoutException {
      return const ProbeAlive();
    } on FormatException {
      return const ProbeAlive();
    } on Exception catch (e) {
      return classify(e);
    } finally {
      client.close(force: true);
    }
  }

  /// A bridge when [json] has a bridge id and a model id.
  static ProbeResult read(Object? json) {
    if (json case {'bridgeid': final String id, 'modelid': String _}) {
      return ProbeBridge(id: id.toLowerCase(), name: '${json['name'] ?? 'Hue Bridge'}');
    }
    return const ProbeAlive();
  }

  /// A refused or reset connection means a host is there; anything else,
  /// such as no route or a connect timeout, means nothing is.
  static ProbeResult classify(Exception error) => switch (error) {
    SocketException(osError: OSError(errorCode: 111 || 104 || 61 || 54)) => const ProbeAlive(),
    SocketException() => const ProbeAbsent(),
    _ => const ProbeAlive(),
  };
}

/// The private IPv4 ranges of RFC 1918: the only ones the sweep scans.
bool isPrivateIPv4(String address) {
  final parts = address.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.contains(null)) return false;
  final [a, b, ...] = parts;
  return a == 10 || (a == 172 && b! >= 16 && b < 32) || (a == 192 && b == 168);
}

/// The private IPv4 addresses of Wi-Fi and Ethernet interfaces, including
/// the phone's own hotspot, and never mobile data or VPNs.
List<String> wifiAddresses(List<NetworkInterface> interfaces) => [
  for (final i in interfaces)
    if (RegExp(r'^(wlan|swlan|ap|eth|en)').hasMatch(i.name))
      for (final a in i.addresses)
        if (isPrivateIPv4(a.address)) a.address,
];

Future<List<String>> localWifiAddresses() async =>
    wifiAddresses(await NetworkInterface.list(type: InternetAddressType.IPv4));
