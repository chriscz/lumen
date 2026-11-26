// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/bridge_api.dart';
import 'package:lumen/emulator/bridge_server.dart';
import 'package:lumen/emulator/dns_message.dart';
import 'package:lumen/emulator/emulator_settings.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/lan_bridge_discovery.dart';
import 'package:lumen/transport/bridge/lan_discovery_sources.dart';

void main() {
  final loopback = InternetAddress.loopbackIPv4;

  group('against the emulated bridge on loopback', () {
    late HomeController home;
    late BridgeServer server;
    late EmulatorSettings settings;

    setUp(() async {
      home = HomeController(AppServices.simulated(central: SimulatedBleCentral(), store: MemoryHomeStore()));
      await home.load();
      settings = EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff', name: 'Lumen');
      server = BridgeServer(
        BridgeApi(home, settings),
        ports: const [0],
        ssdpPort: 0,
        multicastGroup: null,
        mdnsPort: 0,
        mdnsGroup: null,
        addresses: () async => ['127.0.0.1'],
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      home.dispose();
    });

    test('the built-in mDNS query reads port, bridge id and address from a legacy unicast reply', () async {
      final query = MdnsQuery(to: loopback, port: server.boundMdnsPort!, window: const Duration(milliseconds: 400));
      final found = await query.search().toList();
      expect(found, hasLength(1));
      expect(found.single.host, '127.0.0.1');
      expect(found.single.port, server.port);
      expect(found.single.bridgeId, settings.bridgeId.toLowerCase());
    });

    test('the SSDP search reads LOCATION and hue-bridgeid from every target that answers', () async {
      final search = SsdpSearch(
        targets: [(loopback, server.boundSsdpPort!), (InternetAddress('192.0.2.1'), 1900)],
        window: const Duration(milliseconds: 400),
      );
      final found = await search.search().toList();
      expect(found, isNotEmpty);
      expect(
        {for (final c in found) '${c.host}:${c.port} ${c.bridgeId}'},
        {'127.0.0.1:${server.port} ${settings.bridgeId.toLowerCase()}'},
      );
    });

    test('the probe recognises the emulated bridge by its config', () async {
      final result = await HttpConfigProbe()('127.0.0.1', server.port!);
      expect(result, isA<ProbeBridge>().having((b) => b.id, 'id', settings.bridgeId.toLowerCase()));
      expect((result as ProbeBridge).name, 'Lumen');
    });

    test('discovery finds it by every method, once, as a phone bridge', () async {
      final discovery = LanBridgeDiscovery(
        probe: HttpConfigProbe().call,
        mdns: MdnsQuery(to: loopback, port: server.boundMdnsPort!, window: const Duration(milliseconds: 300)).search,
        ssdp: SsdpSearch(
          targets: [(loopback, server.boundSsdpPort!)],
          window: const Duration(milliseconds: 300),
        ).search,
        localAddresses: () async => const [],
      );
      final events = await discovery.discover().toList();
      final found = events.whereType<BridgeFound>().map((e) => e.bridge).toList();
      expect(found, hasLength(1));
      expect(found.single.stage, DiscoveryStage.mdns);
      expect(found.single.address, '127.0.0.1:${server.port}');
      expect(found.single.phone, isTrue);
    });
  });

  group('mDNS replies', () {
    final from = InternetAddress('192.168.1.30');
    const service = '_hue._tcp.local';
    const instance = 'Hue Bridge - 123456.$service';

    test('the query asks for the Hue service by PTR from an ephemeral port', () {
      final query = MdnsQuery.query(7);
      expect(query.id, 7);
      expect(query.questions.single, const DnsQuestion(service, DnsType.ptr));
      expect(MdnsQuery().port, 5353);
      expect(MdnsQuery().to, InternetAddress('224.0.0.251'));
    });

    test('a real bridge reply on 443 with the A record reads host, port and id', () {
      final reply = DnsMessage(
        isResponse: true,
        answers: const [DnsRecord(service, ttl: 10, data: PtrData(instance))],
        additionals: const [
          DnsRecord(instance, ttl: 10, data: SrvData(port: 443, target: 'ecb5fa123456.local')),
          DnsRecord(instance, ttl: 10, data: TxtData(['bridgeid=ECB5FAFFFE123456', 'modelid=BSB002'])),
          DnsRecord('ecb5fa123456.local', ttl: 10, data: AData('192.168.1.2')),
        ],
      );
      final c = MdnsQuery.candidates(reply, from).single;
      expect([c.host, c.port, c.bridgeId], ['192.168.1.2', 443, 'ecb5fafffe123456']);
    });

    test('without an A record the sender is the host, and without TXT there is no id', () {
      final reply = DnsMessage(
        isResponse: true,
        answers: const [
          DnsRecord(service, ttl: 10, data: PtrData(instance)),
          DnsRecord('other._http._tcp.local', ttl: 10, data: PtrData('x')),
          DnsRecord(instance, ttl: 10, data: SrvData(port: 1818, target: 'phone.local')),
          DnsRecord(instance, ttl: 10, data: TxtData(['modelid=BSB002'])),
        ],
      );
      final c = MdnsQuery.candidates(reply, from).single;
      expect([c.host, c.port, c.bridgeId], ['192.168.1.30', 1818, null]);
    });

    test('a query, or a reply without SRV, gives nothing', () {
      expect(MdnsQuery.candidates(MdnsQuery.query(1), from), isEmpty);
      final noSrv = DnsMessage(isResponse: true, answers: const [DnsRecord(service, ttl: 10, data: PtrData(instance))]);
      expect(MdnsQuery.candidates(noSrv, from), isEmpty);
    });

    test('junk datagrams are ignored', () async {
      final junk = await RawDatagramSocket.bind(loopback, 0);
      addTearDown(junk.close);
      junk.listen((event) {
        final d = junk.receive();
        if (d != null) junk.send([1, 2, 3], d.address, d.port);
      });
      final found = await MdnsQuery(
        to: loopback,
        port: junk.port,
        window: const Duration(milliseconds: 200),
      ).search().toList();
      expect(found, isEmpty);
    });

    test('a query that cannot be sent ends quietly', () async {
      // A socket on loopback cannot reach this documentation address.
      final found = await MdnsQuery(
        to: InternetAddress('192.0.2.1'),
        bindAddress: loopback,
        window: const Duration(milliseconds: 100),
      ).search().toList();
      expect(found, isEmpty);
      expect(MdnsQuery().bindAddress, InternetAddress.anyIPv4);
      expect(SsdpSearch().bindAddress, InternetAddress.anyIPv4);
    });
  });

  group('SSDP replies', () {
    String reply(List<String> headers) => ['HTTP/1.1 200 OK', ...headers, '', ''].join('\r\n');

    test('the search asks for everything, on the multicast group and the broadcast address', () {
      expect(SsdpSearch.request, contains('M-SEARCH * HTTP/1.1\r\n'));
      expect(SsdpSearch.request, contains('ST: ssdp:all\r\n'));
      expect(SsdpSearch.request, contains('MAN: "ssdp:discover"\r\n'));
      expect(SsdpSearch.request, endsWith('\r\n\r\n'));
      expect(SsdpSearch().targets, [
        (InternetAddress('239.255.255.250'), 1900),
        (InternetAddress('255.255.255.255'), 1900),
      ]);
    });

    test('a real bridge reply reads host, port 80 and the id', () {
      final c = SsdpSearch.parse(
        reply([
          'LOCATION: http://192.168.1.2:80/description.xml',
          'SERVER: Hue/1.0 UPnP/1.0 IpBridge/1.65.0',
          'hue-bridgeid: 001788FFFE123456',
        ]),
      )!;
      expect([c.host, c.port, c.bridgeId], ['192.168.1.2', 80, '001788fffe123456']);
    });

    test('a location without a port means 80, and IpBridge alone is enough', () {
      final c = SsdpSearch.parse(
        reply(['Location: http://192.168.1.2/description.xml', 'Server: Linux UPnP/1.0 IpBridge/1.16.0']),
      )!;
      expect([c.host, c.port, c.bridgeId], ['192.168.1.2', 80, null]);
    });

    test('other devices, notices and broken locations give nothing', () {
      expect(SsdpSearch.parse(reply(['LOCATION: http://192.168.1.40:8008/dd.xml', 'SERVER: Chromecast'])), isNull);
      expect(SsdpSearch.parse(reply(['hue-bridgeid: 001788FFFE123456'])), isNull);
      expect(SsdpSearch.parse(reply(['LOCATION: ::nope', 'hue-bridgeid: 001788FFFE123456'])), isNull);
      expect(SsdpSearch.parse('NOTIFY * HTTP/1.1\r\nLOCATION: http://1.2.3.4/\r\nhue-bridgeid: x\r\n\r\n'), isNull);
    });
  });

  group('the config probe', () {
    late HttpServer http;
    late Object? Function(String path) answer;

    setUp(() async {
      answer = (_) => {'name': 'Hall', 'bridgeid': '001788FFFE123456', 'modelid': 'BSB002'};
      http = await HttpServer.bind(loopback, 0);
      http.listen((request) async {
        final body = answer(request.uri.path);
        if (body == 'hang') return;
        request.response.write(body is String ? body : jsonEncode(body));
        await request.response.close();
      });
    });

    tearDown(() => http.close(force: true));

    test('asks GET /api/config and keeps an answer with a bridge id and a model id', () async {
      final paths = <String>[];
      answer = (path) {
        paths.add(path);
        return {'name': 'Hall', 'bridgeid': '001788FFFE123456', 'modelid': 'BSB002'};
      };
      final result = await HttpConfigProbe()('127.0.0.1', http.port);
      expect(paths, ['/api/config']);
      expect(result, isA<ProbeBridge>());
      expect((result as ProbeBridge).id, '001788fffe123456');
      expect(result.name, 'Hall');
    });

    test('a name defaults, and answers that are not a bridge say only that something is there', () async {
      answer = (_) => {'bridgeid': '001788FFFE123456', 'modelid': 'BSB002'};
      expect(((await HttpConfigProbe()('127.0.0.1', http.port)) as ProbeBridge).name, 'Hue Bridge');
      for (final body in <Object>[
        {'name': 'router'},
        {'bridgeid': 'x'},
        [1, 2],
        '<html>',
      ]) {
        answer = (_) => body;
        expect(await HttpConfigProbe()('127.0.0.1', http.port), isA<ProbeAlive>(), reason: '$body');
      }
    });

    test('a host that accepts but never answers is there, but not a bridge', () async {
      answer = (_) => 'hang';
      final probe = HttpConfigProbe(timeout: const Duration(milliseconds: 150));
      expect(await probe('127.0.0.1', http.port), isA<ProbeAlive>());
    });

    test('a refused connection means the host is there; no route or a connect timeout means it is not', () async {
      final port = http.port;
      await http.close(force: true);
      expect(await HttpConfigProbe()('127.0.0.1', port), isA<ProbeAlive>());
      expect(HttpConfigProbe.classify(const SocketException('x', osError: OSError('refused', 111))), isA<ProbeAlive>());
      expect(HttpConfigProbe.classify(const SocketException('x', osError: OSError('reset', 104))), isA<ProbeAlive>());
      expect(HttpConfigProbe.classify(const SocketException('x', osError: OSError('refused', 61))), isA<ProbeAlive>());
      expect(
        HttpConfigProbe.classify(const SocketException('x', osError: OSError('no route', 113))),
        isA<ProbeAbsent>(),
      );
      expect(HttpConfigProbe.classify(const SocketException('HTTP connection timed out')), isA<ProbeAbsent>());
      expect(HttpConfigProbe.classify(const HttpException('bad')), isA<ProbeAlive>());
    });

    test('port 443 is asked over HTTPS, accepting the bridge certificate', () async {
      // Nothing listens on 443 on loopback here, so the connection is refused.
      expect(HttpConfigProbe.uriFor('192.168.1.2', 443), Uri.parse('https://192.168.1.2:443/api/config'));
      expect(HttpConfigProbe.uriFor('192.168.1.2', 1818), Uri.parse('http://192.168.1.2:1818/api/config'));
      expect(
        await HttpConfigProbe(connectTimeout: const Duration(milliseconds: 200))('127.0.0.1', 443),
        isNot(isA<ProbeBridge>()),
      );
    });

    test('a simulated bridge on loopback is a bridge', () async {
      final bridge = SimulatedBridge(id: '001788fffe00beef', name: 'Sim');
      final served = await bridge.serve();
      addTearDown(() => served.close(force: true));
      final result = await HttpConfigProbe()('127.0.0.1', served.port);
      expect((result as ProbeBridge).id, '001788fffe00beef');
    });
  });

  group('Wi-Fi addresses', () {
    test('keep private IPv4 addresses on Wi-Fi and Ethernet only', () {
      final interfaces = [
        _Interface('rmnet0', ['100.64.0.2', '10.20.0.2']),
        _Interface('lo', ['127.0.0.1']),
        _Interface('tun0', ['10.8.0.2']),
        _Interface('wlan0', ['192.168.1.20', '169.254.3.3', '8.8.8.8']),
        _Interface('eth0', ['10.0.0.4', '172.16.5.5', '172.32.0.1']),
        _Interface('swlan0', ['192.168.43.1']),
      ];
      expect(wifiAddresses(interfaces), ['192.168.1.20', '10.0.0.4', '172.16.5.5', '192.168.43.1']);
    });

    test('the real interface list gives only private addresses', () async {
      for (final a in await localWifiAddresses()) {
        expect(isPrivateIPv4(a), isTrue, reason: a);
      }
      expect(isPrivateIPv4('not an address'), isFalse);
    });
  });
}

class _Interface implements NetworkInterface {
  _Interface(this.name, List<String> addresses) : addresses = [for (final a in addresses) _Address(a)];

  @override
  final String name;

  @override
  final List<InterfaceAddress> addresses;

  @override
  int get index => 0;
}

class _Address implements InterfaceAddress {
  _Address(String address) : _address = InternetAddress(address);

  final InternetAddress _address;

  @override
  String get address => _address.address;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
