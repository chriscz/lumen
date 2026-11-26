// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../transport/bridge/bridge_ports.dart';
import 'bridge_api.dart';
import 'emulator_settings.dart';
import 'mdns_responder.dart';
import 'nsd.dart';

/// Where the emulated bridge listens, and how it is doing. The UI watches
/// it as a [ChangeNotifier].
abstract class EmulatorServer extends ChangeNotifier {
  bool get running;

  /// The phone's LAN IPv4 addresses, best first.
  List<String> get addresses;
  int? get port;

  /// Whether the SSDP responder runs and announcing is on.
  bool get ssdp;

  /// Whether mDNS announces: Android's registration or the built-in
  /// responder, with announcing and mDNS on.
  bool get mdns;

  /// Which mDNS responder announces, while [mdns]; else null.
  MdnsImplementation? get mdnsVia;

  /// Why Android's mDNS could not register, so the built-in one took over
  /// for this run.
  String? get systemMdnsError;

  /// Why SSDP or mDNS could not start, for the user.
  String? get ssdpError;
  String? get mdnsError;

  /// Why the server could not start, for the user.
  String? get error;

  Future<void> start();

  Future<void> stop();

  /// Applies the settings' discovery switches and mDNS choice: announces
  /// what was switched on and says goodbye for what was switched off.
  Future<void> announcementChanged();
}

/// A short reason for a responder that failed to start.
String responderError(Object error, int port) {
  const addressInUse = {98, 48, 10048};
  if (error is SocketException) {
    if (addressInUse.contains(error.osError?.errorCode)) return 'the multicast port $port is busy';
    return error.osError?.message ?? error.message;
  }
  return '$error';
}

typedef EmulatorServerFactory = EmulatorServer Function(BridgeApi api, List<int> ports, SystemMdns nsd);

/// Serves [BridgeApi] over HTTP on the LAN, with the UPnP description and an
/// SSDP responder, the way a Hue Bridge does. See
/// docs/protocol.md.
class BridgeServer extends EmulatorServer {
  BridgeServer(
    this.api, {
    List<int>? ports,
    this.ssdpPort = SsdpResponder.ssdpPort,
    this.multicastGroup = SsdpResponder.ssdpGroup,
    this.mdnsPort = MdnsResponder.mdnsPort,
    this.mdnsGroup = MdnsResponder.mdnsGroup,
    Future<List<String>> Function()? addresses,
    this.nsd = const NoSystemMdns(),
  }) : ports = ports ?? defaultPorts,
       _lookup = addresses ?? lanAddresses;

  /// The factory the app uses: real sockets on [ports], and [nsd] for mDNS
  /// where the platform has it.
  static BridgeServer create(BridgeApi api, List<int> ports, SystemMdns nsd) =>
      BridgeServer(api, ports: ports, nsd: nsd);

  /// Port 80 is where clients look, but stock Android does not let apps bind
  /// below 1024, so the first free one of [BridgePorts.lan] is the fallback,
  /// which is where clients scan. 0 picks any free port (tests).
  static final defaultPorts = List<int>.unmodifiable([80, ...BridgePorts.lan]);

  final BridgeApi api;
  final List<int> ports;
  final int ssdpPort;

  /// The SSDP multicast group to join; null answers unicast searches only.
  final String? multicastGroup;
  final int mdnsPort;

  /// The mDNS multicast group to join; null answers unicast queries only.
  final String? mdnsGroup;
  final Future<List<String>> Function() _lookup;

  /// Android's mDNS responder, used instead of the built-in one when chosen.
  final SystemMdns nsd;

  HttpServer? _http;
  SsdpResponder? _ssdp;
  MdnsResponder? _mdns;
  String? _ssdpError;
  String? _mdnsError;
  String? _systemMdnsError;

  /// The mDNS responder in use: null before start, else system (registered
  /// while [_registered]) or the built-in [_mdns].
  MdnsImplementation? _impl;
  bool _registered = false;
  bool _mdnsWasActive = false;
  bool _ssdpWasActive = false;
  bool _running = false;
  List<String> _addresses = const [];
  int? _port;
  String? _error;

  @override
  bool get running => _running;

  @override
  List<String> get addresses => _addresses;

  @override
  int? get port => _port;

  EmulatorSettings get _settings => api.settings;
  bool get _ssdpActive => _settings.announce && _settings.ssdpEnabled;
  bool get _mdnsActive => _settings.announce && _settings.mdnsEnabled;

  @override
  bool get ssdp => _ssdp != null && _ssdpActive;

  @override
  bool get mdns => _mdnsActive && (_registered || (_impl == MdnsImplementation.builtIn && _mdns != null));

  @override
  MdnsImplementation? get mdnsVia => mdns ? _impl : null;

  @override
  String? get systemMdnsError => _systemMdnsError;

  @override
  String? get ssdpError => _ssdpError;

  @override
  String? get mdnsError => _mdnsError;

  /// The bound discovery ports, once started (tests).
  int? get boundSsdpPort => _ssdp?.boundPort;
  int? get boundMdnsPort => _mdns?.boundPort;

  @override
  String? get error => _error;

  /// The phone's IPv4 addresses, Wi-Fi first and mobile data last.
  static Future<List<String>> lanAddresses() async =>
      orderAddresses(await NetworkInterface.list(type: InternetAddressType.IPv4));

  /// The addresses of [interfaces], Wi-Fi first and mobile data last,
  /// without loopback or link-local ones.
  @visibleForTesting
  static List<String> orderAddresses(List<NetworkInterface> interfaces) {
    int rank(NetworkInterface i) => switch (i.name) {
      final n when n.startsWith('wlan') => 0,
      final n when n.startsWith('eth') || n.startsWith('en') => 1,
      final n when n.startsWith('rmnet') || n.startsWith('tun') => 3,
      _ => 2,
    };
    final sorted = [...interfaces]..sort((a, b) => rank(a).compareTo(rank(b)));
    return [
      for (final i in sorted)
        for (final a in i.addresses)
          if (!a.isLoopback && !a.isLinkLocal) a.address,
    ];
  }

  @override
  Future<void> start() async {
    if (_running) return;
    _error = _ssdpError = _mdnsError = _systemMdnsError = null;
    Object? failure;
    for (final p in ports) {
      try {
        _http = await HttpServer.bind(InternetAddress.anyIPv4, p);
        break;
      } on SocketException catch (e) {
        failure = e;
      }
    }
    final http = _http;
    if (http == null) {
      _error = 'Could not listen on port ${ports.join(' or ')}: $failure';
      notifyListeners();
      return;
    }
    _port = http.port;
    try {
      _addresses = await _lookup();
    } on SocketException {
      _addresses = const [];
    }
    api.ipAddress = _addresses.firstOrNull ?? '127.0.0.1';
    http.listen(_serve);
    final responder = SsdpResponder(
      settings: api.settings,
      location: (sender) => 'http://${hostFor(sender, _addresses)}:$_port/description.xml',
      port: ssdpPort,
      multicastGroup: multicastGroup,
      active: () => _ssdpActive,
    );
    _ssdpWasActive = _ssdpActive;
    try {
      await responder.start();
      _ssdp = responder;
    } on Object catch (e) {
      debugPrint('SSDP unavailable: $e');
      _ssdpError = responderError(e, ssdpPort);
      await responder.stop();
    }
    await _applyMdns();
    _running = true;
    notifyListeners();
  }

  /// The mDNS responder the settings ask for: Android's while it is chosen
  /// and has not failed this run, else the built-in one.
  MdnsImplementation get _wantedMdns {
    final wanted = _settings.mdnsWanted(systemAvailable: nsd.available);
    if (wanted == MdnsImplementation.builtIn) _systemMdnsError = null;
    return wanted == MdnsImplementation.system && _systemMdnsError == null
        ? MdnsImplementation.system
        : MdnsImplementation.builtIn;
  }

  /// Brings mDNS in line with the settings: swaps the responder when the
  /// choice changed, and registers, announces, unregisters or says goodbye
  /// when mDNS was switched on or off.
  Future<void> _applyMdns() async {
    final wanted = _wantedMdns;
    if (wanted != _impl) {
      if (_registered) await nsd.unregister();
      _registered = false;
      await _mdns?.stop();
      _mdns = null;
      _impl = wanted;
      if (wanted == MdnsImplementation.builtIn) await _startBuiltIn();
      _mdnsWasActive = _mdnsActive;
    }
    final active = _mdnsActive;
    if (_impl == MdnsImplementation.system) {
      if (active && !_registered) {
        final error = await nsd.register(
          name: MdnsResponder.label(_settings),
          port: _port!,
          txt: MdnsResponder.txtFor(_settings),
        );
        if (error == null) {
          _registered = true;
        } else {
          debugPrint('Android mDNS failed, using the built-in responder: $error');
          _systemMdnsError = error;
          return _applyMdns();
        }
      } else if (!active && _registered) {
        await nsd.unregister();
        _registered = false;
      }
    } else if (active != _mdnsWasActive) {
      active ? _mdns?.announce() : _mdns?.goodbye();
    }
    _mdnsWasActive = active;
  }

  Future<void> _startBuiltIn() async {
    _mdnsError = null;
    final mdns = MdnsResponder.forBridge(
      _settings,
      httpPort: _port!,
      address: api.ipAddress,
      port: mdnsPort,
      multicastGroup: mdnsGroup,
      active: () => _mdnsActive,
    );
    try {
      await mdns.start();
      _mdns = mdns;
    } on Object catch (e) {
      debugPrint('mDNS unavailable: $e');
      _mdnsError = responderError(e, mdnsPort);
      await mdns.stop();
    }
  }

  @override
  Future<void> stop() async {
    await _ssdp?.stop();
    _ssdp = null;
    await _mdns?.stop();
    _mdns = null;
    if (_registered) await nsd.unregister();
    _registered = false;
    _impl = null;
    await _http?.close(force: true);
    _http = null;
    if (!_running) return;
    _running = false;
    _port = null;
    notifyListeners();
  }

  @override
  Future<void> announcementChanged() async {
    if (!_running) return notifyListeners();
    final ssdp = _ssdpActive;
    if (ssdp != _ssdpWasActive) ssdp ? _ssdp?.announce() : _ssdp?.byebye();
    _ssdpWasActive = ssdp;
    await _applyMdns();
    notifyListeners();
  }

  /// The address to give a client: loopback to itself, else the one of
  /// [addresses] on the client's subnet, else the best.
  @visibleForTesting
  static String hostFor(InternetAddress sender, List<String> addresses) {
    if (sender.isLoopback) return '127.0.0.1';
    final prefix = sender.address.substring(0, sender.address.lastIndexOf('.') + 1);
    return addresses.where((a) => a.startsWith(prefix)).firstOrNull ?? addresses.firstOrNull ?? '127.0.0.1';
  }

  static void _cors(HttpHeaders headers) {
    headers
      ..set('access-control-allow-origin', '*')
      ..set('access-control-allow-methods', 'GET, POST, PUT, DELETE, OPTIONS')
      ..set('access-control-allow-headers', 'Content-Type, hue-application-key')
      ..set('access-control-max-age', '3600');
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    _cors(response.headers);
    try {
      final path = request.uri.path;
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
      } else if (request.method == 'GET' && path == '/description.xml') {
        final host = request.headers.host ?? api.ipAddress;
        final port = request.headers.port ?? _port;
        response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
        response.write(description(api.settings, host: host, port: port ?? 80));
      } else {
        final bytes = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
        final headers = <String, String>{};
        request.headers.forEach((name, values) => headers[name] = values.join(','));
        final (status, json) = api.handle(
          request.method,
          path,
          utf8.decode(bytes, allowMalformed: true),
          headers: headers,
        );
        response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(json));
      }
    } on Object catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      debugPrint('Bridge emulator: $e');
    }
    await response.close();
  }

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  /// The UPnP device description clients read to recognise a Hue bridge.
  static String description(EmulatorSettings settings, {required String host, required int port}) =>
      '''
<?xml version="1.0" encoding="UTF-8" ?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
<specVersion>
<major>1</major>
<minor>0</minor>
</specVersion>
<URLBase>http://$host:$port/</URLBase>
<device>
<deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
<friendlyName>${_escape(settings.name)} ($host)</friendlyName>
<manufacturer>Lumen</manufacturer>
<manufacturerURL>https://github.com/chriscz/lumen</manufacturerURL>
<modelDescription>Lumen, acting as a Hue Bridge</modelDescription>
<modelName>Philips hue bridge 2015</modelName>
<modelNumber>${BridgeApi.modelId}</modelNumber>
<modelURL>https://github.com/chriscz/lumen</modelURL>
<serialNumber>${settings.serial}</serialNumber>
<UDN>${settings.udn}</UDN>
<presentationURL>index.html</presentationURL>
</device>
</root>
''';
}

/// Answers SSDP searches for a Hue bridge, announces it when it starts and
/// every minute after, and says ssdp:byebye when it stops. While [active]
/// is false it stays silent.
class SsdpResponder {
  SsdpResponder({
    required this.settings,
    required this.location,
    this.port = ssdpPort,
    InternetAddress? bindAddress,
    this.multicastGroup = ssdpGroup,
    (InternetAddress, int)? notifyTo,
    bool Function()? active,
    this.reopenDelay = const Duration(seconds: 5),
  }) : bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       notifyTo = notifyTo ?? (multicastGroup == null ? null : (InternetAddress(multicastGroup), ssdpPort)),
       _active = active ?? (() => true);

  static const ssdpGroup = '239.255.255.250';
  static const ssdpPort = 1900;
  static const server = 'Linux/3.14.0 UPnP/1.0 IpBridge/${BridgeApi.apiVersion}';
  static const basicDevice = 'urn:schemas-upnp-org:device:basic:1';

  final EmulatorSettings settings;

  /// The description URL to hand to a client at the given address.
  final String Function(InternetAddress sender) location;

  /// The port to listen on; 0 picks a free one (tests).
  final int port;
  final InternetAddress bindAddress;
  final String? multicastGroup;

  /// Where NOTIFY announcements go; null sends none.
  final (InternetAddress, int)? notifyTo;
  final bool Function() _active;

  /// How long to wait before opening a new socket when the old one failed.
  final Duration reopenDelay;

  RawDatagramSocket? _socket;
  Timer? _announce;
  Timer? _reopen;
  bool _alive = false;

  /// The bound port, once started.
  int? get boundPort => _socket?.port;

  Future<void> start() async {
    _reopen?.cancel();
    final socket = await RawDatagramSocket.bind(bindAddress, port);
    _socket = socket;
    if (multicastGroup case final group?) {
      try {
        socket.joinMulticast(InternetAddress(group));
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
        final request = utf8.decode(datagram.data, allowMalformed: true);
        for (final answer in answers(request, settings: settings, location: location(datagram.address))) {
          socket.send(utf8.encode(answer), datagram.address, datagram.port);
        }
      },
      // A datagram that cannot be sent, as when the network goes away, is
      // reported here rather than thrown by send, and dart:io then closes
      // the socket. A new one takes over after [reopenDelay].
      onError: (Object e) {
        debugPrint('SSDP socket error: $e');
        if (!identical(_socket, socket)) return;
        _socket = null;
        _announce?.cancel();
        _reopen = Timer(reopenDelay, () async {
          try {
            await start();
          } on Object catch (e) {
            debugPrint('SSDP could not reopen: $e');
          }
        });
      },
    );
    announce();
  }

  /// Sends ssdp:alive now and every minute, while active.
  void announce() {
    _announce?.cancel();
    _notify();
    _announce = Timer.periodic(const Duration(minutes: 1), (_) => _notify());
  }

  /// Sends ssdp:byebye if alive was sent, and stops announcing.
  void byebye() {
    _announce?.cancel();
    _announce = null;
    if (!_alive) return;
    _alive = false;
    _send(byebyes(settings: settings));
  }

  Future<void> stop() async {
    _reopen?.cancel();
    byebye();
    _socket?.close();
    _socket = null;
  }

  void _notify() {
    final address = notifyTo?.$1;
    if (address == null || _socket == null || !_active()) return;
    _alive = true;
    _send(notifications(settings: settings, location: location(address)));
  }

  void _send(List<String> messages) {
    final (address, port) = notifyTo ?? (null, 0);
    final socket = _socket;
    if (address == null || socket == null) return;
    for (final message in messages) {
      socket.send(utf8.encode(message), address, port);
    }
  }

  /// The ssdp:byebye notices, one per target, sent when the bridge leaves.
  static List<String> byebyes({required EmulatorSettings settings}) => [
    for (final target in _targets(settings))
      _message([
        'NOTIFY * HTTP/1.1',
        'HOST: $ssdpGroup:$ssdpPort',
        'NTS: ssdp:byebye',
        'hue-bridgeid: ${settings.bridgeId}',
        'NT: $target',
        'USN: ${_usn(settings, target)}',
      ]),
  ];

  static List<String> _targets(EmulatorSettings settings) => ['upnp:rootdevice', settings.udn, basicDevice];

  static String _usn(EmulatorSettings settings, String target) =>
      target == settings.udn ? settings.udn : '${settings.udn}::$target';

  static String _message(List<String> lines) => '${lines.join('\r\n')}\r\n\r\n';

  /// The replies to one SSDP datagram: none unless it is an M-SEARCH for
  /// everything, a root device, this bridge's uuid or a basic device.
  static List<String> answers(String request, {required EmulatorSettings settings, required String location}) {
    final lines = request.split(RegExp(r'\r?\n'));
    if (!lines.first.toUpperCase().startsWith('M-SEARCH')) return const [];
    final headers = {
      for (final line in lines.skip(1))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim().toLowerCase(): line.substring(line.indexOf(':') + 1).trim(),
    };
    final st = (headers['st'] ?? '').toLowerCase();
    final targets = st == 'ssdp:all' ? _targets(settings) : _targets(settings).where((t) => t.toLowerCase() == st);
    return [
      for (final target in targets)
        _message([
          'HTTP/1.1 200 OK',
          'HOST: $ssdpGroup:$ssdpPort',
          'EXT:',
          'CACHE-CONTROL: max-age=100',
          'LOCATION: $location',
          'SERVER: $server',
          'hue-bridgeid: ${settings.bridgeId}',
          'ST: $target',
          'USN: ${_usn(settings, target)}',
        ]),
    ];
  }

  /// The ssdp:alive announcements, one per target.
  static List<String> notifications({required EmulatorSettings settings, required String location}) => [
    for (final target in _targets(settings))
      _message([
        'NOTIFY * HTTP/1.1',
        'HOST: $ssdpGroup:$ssdpPort',
        'CACHE-CONTROL: max-age=100',
        'LOCATION: $location',
        'SERVER: $server',
        'NTS: ssdp:alive',
        'hue-bridgeid: ${settings.bridgeId}',
        'NT: $target',
        'USN: ${_usn(settings, target)}',
      ]),
  ];
}

/// A server that binds no sockets, for widget tests and the simulated app:
/// it reports itself running at a made-up LAN address.
class InProcessEmulatorServer extends EmulatorServer {
  InProcessEmulatorServer(this.api, this.ports, [this.nsd = const NoSystemMdns()]);

  final BridgeApi api;
  final List<int> ports;

  /// Only asked whether it is available, to report which mDNS would run.
  final SystemMdns nsd;
  bool _running = false;

  @override
  bool get running => _running;

  @override
  List<String> get addresses => _running ? const ['192.168.1.50'] : const [];

  /// The first port after 80, as on a phone, which may not bind below 1024.
  @override
  int? get port => _running ? ports.firstWhere((p) => p != 80, orElse: () => ports.first) : null;

  @override
  bool get ssdp => _running && api.settings.announce && api.settings.ssdpEnabled;

  @override
  bool get mdns => _running && api.settings.announce && api.settings.mdnsEnabled;

  @override
  MdnsImplementation? get mdnsVia => mdns ? api.settings.mdnsWanted(systemAvailable: nsd.available) : null;

  @override
  String? get systemMdnsError => null;

  @override
  String? get ssdpError => null;

  @override
  String? get mdnsError => null;

  @override
  String? get error => null;

  @override
  Future<void> announcementChanged() async => notifyListeners();

  @override
  Future<void> start() async {
    _running = true;
    api.ipAddress = addresses.first;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    notifyListeners();
  }
}
