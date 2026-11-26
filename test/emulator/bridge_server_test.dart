// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumen/domain/light.dart';
import 'package:lumen/emulator/bridge_api.dart';
import 'package:lumen/emulator/dns_message.dart';
import 'package:lumen/emulator/bridge_server.dart';
import 'package:lumen/emulator/emulator_settings.dart';
import 'package:lumen/emulator/nsd.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge_platform.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/bridge_ports.dart';
import 'package:lumen/transport/bridge/hue_bridge_client.dart';

void main() {
  late SimulatedBleCentral central;
  late HomeController home;
  late BridgeApi api;
  late BridgeServer server;
  late String desk, hall;

  Future<List<String>> loopback() async => ['127.0.0.1'];

  BridgeServer local({List<int> ports = const [0], int ssdpPort = 0, int mdnsPort = 0, SystemMdns? nsd}) =>
      BridgeServer(
        api,
        ports: ports,
        ssdpPort: ssdpPort,
        multicastGroup: null,
        mdnsPort: mdnsPort,
        mdnsGroup: null,
        addresses: loopback,
        nsd: nsd ?? const NoSystemMdns(),
      );

  setUp(() async {
    central = SimulatedBleCentral(scanDelay: Duration.zero)
      ..addBulb(SimulatedHueBulb(id: 'aa', name: 'Desk'))
      ..addBulb(SimulatedHueBulb(id: 'bb', name: 'Hall', model: 'LWA001'));
    home = HomeController(AppServices.simulated(central: central, store: MemoryHomeStore()));
    await home.load();
    for (final id in ['aa', 'bb']) {
      final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == id);
      await home.addBluetoothLight(found);
    }
    [desk, hall] = [for (final l in home.lights) l.id];
    await home.createRoom('Study', [desk, hall]);
    api = BridgeApi(home, EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff', name: 'Lumen'));
    // SSDP and mDNS off the real ports, so tests never meet a real network.
    server = local();
  });

  tearDown(() async {
    await server.stop();
    home.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: 'condition not met in time');
  }

  test('starts on a free port and reports its status', () async {
    var notified = 0;
    server.addListener(() => notified++);
    await server.start();
    expect(server.running, isTrue);
    expect(server.port, greaterThan(0));
    expect(server.addresses, ['127.0.0.1']);
    expect(server.ssdp, isTrue);
    expect(server.mdns, isTrue);
    expect(server.ssdpError, isNull);
    expect(server.mdnsError, isNull);
    expect(notified, greaterThan(0));
    expect(api.ipAddress, '127.0.0.1');
    await server.stop();
    expect(server.running, isFalse);
  });

  test('tries port 80 first, then the phone bridge ports', () {
    expect(BridgeServer.defaultPorts, [80, ...BridgePorts.lan]);
    expect(BridgeServer(api).ports, BridgeServer.defaultPorts);
    expect(BridgeServer(api).nsd, isA<NoSystemMdns>());
  });

  test('tries the ports in order and takes the first one that is free', () async {
    final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(blocker.close);
    server = local(ports: [blocker.port, 0]);
    await server.start();
    expect(server.running, isTrue);
    expect(server.port, isNot(blocker.port));
  });

  test('keeps serving HTTP when the SSDP port is taken', () async {
    final blocker = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: false);
    addTearDown(blocker.close);
    server = local(ssdpPort: blocker.port);
    await server.start();
    expect(server.running, isTrue);
    expect(server.ssdp, isFalse);
    expect(server.ssdpError, 'the multicast port ${blocker.port} is busy');
    expect(server.mdns, isTrue);
    final response = await http.get(Uri.parse('http://127.0.0.1:${server.port}/api/config'));
    expect(jsonDecode(response.body)['bridgeid'], 'AABBCCFFFEDDEEFF');
  });

  test('keeps serving HTTP and SSDP when the mDNS port is taken', () async {
    final blocker = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: false);
    addTearDown(blocker.close);
    server = local(mdnsPort: blocker.port);
    await server.start();
    expect(server.running, isTrue);
    expect(server.mdns, isFalse);
    expect(server.mdnsError, 'the multicast port ${blocker.port} is busy');
    expect(server.ssdp, isTrue);
  });

  test('with announcing off nothing answers discovery, HTTP still works, and switching it on answers', () async {
    api.settings.announce = false;
    await server.start();
    final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(probe.close);
    final replies = <List<int>>[];
    probe.listen((event) {
      if (event != RawSocketEvent.read) return;
      if (probe.receive() case final d?) replies.add(d.data);
    });
    void ask() {
      probe.send(
        utf8.encode('M-SEARCH * HTTP/1.1\r\nMAN: "ssdp:discover"\r\nST: ssdp:all\r\n\r\n'),
        InternetAddress.loopbackIPv4,
        server.boundSsdpPort!,
      );
      probe.send(
        const DnsMessage(questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr, unicastResponse: true)]).encode(),
        InternetAddress.loopbackIPv4,
        server.boundMdnsPort!,
      );
    }

    ask();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(replies, isEmpty);
    final response = await http.get(Uri.parse('http://127.0.0.1:${server.port}/api/config'));
    expect(response.statusCode, 200);

    api.settings.announce = true;
    await server.announcementChanged();
    ask();
    await until(() => replies.length >= 4);
    final texts = [for (final r in replies) utf8.decode(r, allowMalformed: true)];
    expect(texts.where((t) => t.startsWith('HTTP/1.1 200 OK')), hasLength(3));
    final mdns = [
      for (final r in replies)
        if (!utf8.decode(r, allowMalformed: true).startsWith('HTTP/')) DnsMessage.decode(r),
    ];
    expect((mdns.single.answers.single.data as PtrData).name, 'Lumen-DDEEFF._hue._tcp.local');
    expect(mdns.single.additionals.map((r) => r.data).whereType<SrvData>().single.port, server.port);
  });

  group('discovery switches', () {
    late RawDatagramSocket probe;
    final replies = <String>[];

    setUp(() async {
      replies.clear();
      probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      probe.listen((event) {
        if (event != RawSocketEvent.read) return;
        if (probe.receive() case final d?) replies.add(utf8.decode(d.data, allowMalformed: true));
      });
    });

    tearDown(() => probe.close());

    void ask() {
      if (server.boundSsdpPort case final port?) {
        probe.send(
          utf8.encode('M-SEARCH * HTTP/1.1\r\nMAN: "ssdp:discover"\r\nST: ssdp:all\r\n\r\n'),
          InternetAddress.loopbackIPv4,
          port,
        );
      }
      if (server.boundMdnsPort case final port?) {
        probe.send(
          const DnsMessage(questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr, unicastResponse: true)]).encode(),
          InternetAddress.loopbackIPv4,
          port,
        );
      }
    }

    int ssdpReplies() => replies.where((t) => t.startsWith('HTTP/1.1 200 OK')).length;
    int mdnsReplies() => replies.where((t) => !t.startsWith('HTTP/')).length;

    test('mDNS off stops its answers at once while SSDP keeps answering', () async {
      await server.start();
      api.settings.mdnsEnabled = false;
      await server.announcementChanged();
      expect(server.mdns, isFalse);
      expect(server.ssdp, isTrue);
      expect(server.mdnsVia, isNull);
      ask();
      await until(() => ssdpReplies() >= 3);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(mdnsReplies(), 0);

      api.settings.mdnsEnabled = true;
      await server.announcementChanged();
      expect(server.mdns, isTrue);
      ask();
      await until(() => mdnsReplies() >= 1);
    });

    test('SSDP off stops M-SEARCH answers while mDNS keeps answering', () async {
      await server.start();
      api.settings.ssdpEnabled = false;
      await server.announcementChanged();
      expect(server.ssdp, isFalse);
      expect(server.mdns, isTrue);
      ask();
      await until(() => mdnsReplies() >= 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ssdpReplies(), 0);
      api.settings.ssdpEnabled = true;
      await server.announcementChanged();
      ask();
      await until(() => ssdpReplies() >= 3);
    });

    test('with Android mDNS it registers _hue._tcp and binds no mDNS socket of its own', () async {
      final nsd = SimulatedSystemMdns();
      server = local(nsd: nsd);
      await server.start();
      expect(server.mdns, isTrue);
      expect(server.mdnsVia, MdnsImplementation.system);
      expect(server.boundMdnsPort, isNull);
      expect(server.systemMdnsError, isNull);
      expect(nsd.registered?.name, 'Lumen-DDEEFF');
      expect(nsd.registered?.port, server.port);
      expect(nsd.registered?.txt, {'bridgeid': 'aabbccfffeddeeff', 'modelid': 'BSB002'});
      await server.announcementChanged();
      expect(nsd.calls, ['register'], reason: 'nothing changed, so nothing is sent');

      api.settings.mdnsEnabled = false;
      await server.announcementChanged();
      expect(nsd.registered, isNull);
      expect(server.mdns, isFalse);
      api.settings.mdnsEnabled = true;
      await server.announcementChanged();
      expect(nsd.registered, isNotNull);
      api.settings.announce = false;
      await server.announcementChanged();
      expect(nsd.registered, isNull, reason: 'Announce on Wi-Fi off turns every mechanism off');
      expect(server.ssdp, isFalse);
      api.settings.announce = true;
      await server.announcementChanged();
      expect(nsd.registered, isNotNull);

      await server.stop();
      expect(nsd.registered, isNull);
      expect(nsd.calls.last, 'unregister');
    });

    test('with announcing off at start Android mDNS registers only once it is on', () async {
      final nsd = SimulatedSystemMdns();
      server = local(nsd: nsd);
      api.settings.announce = false;
      await server.start();
      expect(nsd.calls, isEmpty);
      expect(server.boundMdnsPort, isNull);
      api.settings.announce = true;
      await server.announcementChanged();
      expect(nsd.registered, isNotNull);
    });

    test('a failed Android registration falls back to the built-in responder and says why', () async {
      final nsd = SimulatedSystemMdns()..failWith = 'NsdManager error 3';
      server = local(nsd: nsd);
      await server.start();
      expect(server.mdns, isTrue);
      expect(server.mdnsVia, MdnsImplementation.builtIn);
      expect(server.systemMdnsError, 'NsdManager error 3');
      expect(server.boundMdnsPort, isNotNull);
      ask();
      await until(() => mdnsReplies() >= 1);

      await server.announcementChanged();
      expect(nsd.calls, ['register'], reason: 'no retry for the rest of the run');

      nsd.failWith = null;
      api.settings.mdnsImplementation = MdnsImplementation.builtIn;
      await server.announcementChanged();
      expect(server.systemMdnsError, isNull, reason: 'choosing built-in clears the note');
      api.settings.mdnsImplementation = MdnsImplementation.system;
      await server.announcementChanged();
      expect(server.mdnsVia, MdnsImplementation.system, reason: 'choosing Android again retries');
      expect(server.boundMdnsPort, isNull);
    });

    test('switching the implementation while running swaps them at once', () async {
      final nsd = SimulatedSystemMdns();
      server = local(nsd: nsd);
      await server.start();
      expect(server.mdnsVia, MdnsImplementation.system);
      api.settings.mdnsImplementation = MdnsImplementation.builtIn;
      await server.announcementChanged();
      expect(nsd.registered, isNull);
      expect(server.mdnsVia, MdnsImplementation.builtIn);
      expect(server.boundMdnsPort, isNotNull);
      ask();
      await until(() => mdnsReplies() >= 1);
      api.settings.mdnsImplementation = MdnsImplementation.system;
      await server.announcementChanged();
      expect(server.boundMdnsPort, isNull);
      expect(server.mdnsVia, MdnsImplementation.system);
      expect(nsd.registered, isNotNull);
    });

    test('the built-in responder is used where Android mDNS is unavailable, whatever was chosen', () async {
      final nsd = SimulatedSystemMdns(available: false);
      server = local(nsd: nsd);
      api.settings.mdnsImplementation = MdnsImplementation.system;
      await server.start();
      expect(server.mdnsVia, MdnsImplementation.builtIn);
      expect(server.systemMdnsError, isNull);
      expect(nsd.calls, isEmpty);
    });
  });

  test('serves a UPnP description that names a Hue bridge', () async {
    await server.start();
    final response = await http.get(Uri.parse('http://127.0.0.1:${server.port}/description.xml'));
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], contains('xml'));
    final xml = response.body;
    expect(xml, contains('<friendlyName>Lumen (127.0.0.1)</friendlyName>'));
    expect(xml, contains('<modelName>Philips hue bridge 2015</modelName>'));
    expect(xml, contains('<modelNumber>BSB002</modelNumber>'));
    expect(xml, contains('<serialNumber>aabbccddeeff</serialNumber>'));
    expect(xml, contains('<UDN>uuid:2f402f80-da50-11e1-9b23-aabbccddeeff</UDN>'));
    expect(xml, contains('<URLBase>http://127.0.0.1:${server.port}/</URLBase>'));
    expect(xml, isNot(contains('<manufacturer>Signify')));
  });

  test('answers browsers with CORS headers, including preflight', () async {
    await server.start();
    final client = HttpClient();
    addTearDown(client.close);
    final preflight = await (await client.openUrl(
      'OPTIONS',
      Uri.parse('http://127.0.0.1:${server.port}/api/x/lights/1/state'),
    )).close();
    expect(preflight.statusCode, lessThan(300));
    expect(preflight.headers.value('access-control-allow-origin'), '*');
    expect(preflight.headers.value('access-control-allow-methods'), contains('PUT'));
    final response = await http.get(Uri.parse('http://127.0.0.1:${server.port}/api/config'));
    expect(response.headers['access-control-allow-origin'], '*');
    expect(response.headers['content-type'], contains('application/json'));
  });

  test("hands a plugin the app key from the hue-application-key header, and lets browsers send it", () async {
    api.settings.users['k'] = PairedApp(username: 'k', devicetype: 't#t', created: DateTime.utc(2026));
    api.extensions.register(
      plugin: 'echo',
      version: '1.0.0',
      title: 'Echo',
      handler: (r) => (200, {'key': r.appKey}),
    );
    await server.start();
    final url = Uri.parse('http://127.0.0.1:${server.port}/__plugins__/echo/v1.0.0/');
    final response = await http.get(url, headers: {'hue-application-key': 'k'});
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {'key': 'k'});
    expect((await http.get(url)).statusCode, 401);
    final client = HttpClient();
    addTearDown(client.close);
    final preflight = await (await client.openUrl('OPTIONS', url)).close();
    expect(preflight.headers.value('access-control-allow-headers'), contains('hue-application-key'));
  });

  test('an unknown path is a 404', () async {
    await server.start();
    final response = await http.get(Uri.parse('http://127.0.0.1:${server.port}/nothing'));
    expect(response.statusCode, 404);
  });

  test('the app\'s own bridge client pairs, lists lights and switches a bulb and a room', () async {
    await server.start();
    final client = HueBridgeClient(http.Client(), Uri.parse('http://127.0.0.1:${server.port}'));

    final config = await client.config();
    expect(config.id, 'aabbccfffeddeeff');
    expect(config.name, 'Lumen');

    await expectLater(client.pair(), throwsA(anything));
    api.pressLinkButton();
    final key = await client.waitForLinkButton(interval: const Duration(milliseconds: 10));

    final lights = await client.lights(key);
    expect(lights.map((l) => l.name), ['Desk', 'Hall']);

    await client.setState(key, lights.first.id, const LightCommand(on: true));
    await until(() => central.bulbs['aa']!.state.on == true);
    expect(central.bulbs['bb']!.state.on, isFalse);

    final groups = await client.groups(key);
    final study = groups.singleWhere((g) => g.name == 'Study');
    expect(study.isRoom, isTrue);
    expect(study.lightIds, hasLength(2));
    await client.groupAction(key, study.id, const LightCommand(on: false));
    await client.groupAction(key, study.id, const LightCommand(on: true));
    await until(() => central.bulbs['bb']!.state.on == true);
    await client.groupAction(key, study.id, const LightCommand(on: false));
    await until(() => central.bulbs['aa']!.state.on == false && central.bulbs['bb']!.state.on == false);
  });

  group('SSDP', () {
    late SsdpResponder responder;
    late RawDatagramSocket probe;
    final replies = <String>[];
    var active = true;

    setUp(() async {
      replies.clear();
      active = true;
      probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      probe.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = probe.receive();
        if (datagram != null) replies.add(utf8.decode(datagram.data));
      });
      responder = SsdpResponder(
        settings: api.settings,
        location: (_) => 'http://127.0.0.1:1818/description.xml',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: null,
        notifyTo: (InternetAddress.loopbackIPv4, probe.port),
        active: () => active,
      );
    });

    tearDown(() async {
      await responder.stop();
      probe.close();
    });

    Map<String, String> headers(String message) => {
      for (final line in message.split('\r\n').skip(1))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).toLowerCase(): line.substring(line.indexOf(':') + 1).trim(),
    };

    Future<List<String>> search(String st, {int expect = 1}) async {
      replies.clear();
      final message = [
        'M-SEARCH * HTTP/1.1',
        'HOST: 239.255.255.250:1900',
        'MAN: "ssdp:discover"',
        'MX: 1',
        'ST: $st',
        '',
        '',
      ].join('\r\n');
      probe.send(utf8.encode(message), InternetAddress.loopbackIPv4, responder.boundPort!);
      for (var i = 0; i < 100 && replies.length < expect; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return [...replies];
    }

    test('sends NOTIFY alive when it starts', () async {
      await responder.start();
      for (var i = 0; i < 100 && replies.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final notify = replies.firstWhere((r) => r.startsWith('NOTIFY * HTTP/1.1'));
      final h = headers(notify);
      expect(h['nts'], 'ssdp:alive');
      expect(h['location'], 'http://127.0.0.1:1818/description.xml');
      expect(h['hue-bridgeid'], 'AABBCCFFFEDDEEFF');
      expect(h['server'], 'Linux/3.14.0 UPnP/1.0 IpBridge/1.56.0');
    });

    test('sends ssdp:byebye for each target when it stops', () async {
      await responder.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      replies.clear();
      await responder.stop();
      for (var i = 0; i < 100 && replies.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(replies, hasLength(3));
      for (final r in replies) {
        expect(r, startsWith('NOTIFY * HTTP/1.1\r\n'));
        expect(headers(r)['nts'], 'ssdp:byebye');
        expect(headers(r).containsKey('location'), isFalse);
      }
      expect(
        [for (final r in replies) headers(r)['nt']],
        ['upnp:rootdevice', 'uuid:2f402f80-da50-11e1-9b23-aabbccddeeff', 'urn:schemas-upnp-org:device:basic:1'],
      );
    });

    test('while inactive it sends no NOTIFY, answers no search and says no byebye', () async {
      active = false;
      await responder.start();
      expect(await search('ssdp:all'), isEmpty);
      await responder.stop();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(replies, isEmpty);
    });

    test('answers M-SEARCH for upnp:rootdevice with one reply in the bridge\'s shape', () async {
      await responder.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final answers = await search('upnp:rootdevice');
      expect(answers, hasLength(1));
      expect(answers.single, startsWith('HTTP/1.1 200 OK\r\n'));
      expect(answers.single, endsWith('\r\n\r\n'));
      final h = headers(answers.single);
      expect(h['location'], 'http://127.0.0.1:1818/description.xml');
      expect(h['server'], 'Linux/3.14.0 UPnP/1.0 IpBridge/1.56.0');
      expect(h['hue-bridgeid'], 'AABBCCFFFEDDEEFF');
      expect(h['st'], 'upnp:rootdevice');
      expect(h['usn'], 'uuid:2f402f80-da50-11e1-9b23-aabbccddeeff::upnp:rootdevice');
      expect(h.containsKey('ext'), isTrue);
      expect(h['cache-control'], startsWith('max-age='));
    });

    test('answers ssdp:all with the root device, the uuid and the basic device', () async {
      await responder.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final answers = await search('ssdp:all', expect: 3);
      expect(
        [for (final a in answers) headers(a)['st']],
        ['upnp:rootdevice', 'uuid:2f402f80-da50-11e1-9b23-aabbccddeeff', 'urn:schemas-upnp-org:device:basic:1'],
      );
    });

    test('answers the basic device search and ignores other searches', () async {
      await responder.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final basic = await search('urn:schemas-upnp-org:device:basic:1');
      expect(
        headers(basic.single)['usn'],
        'uuid:2f402f80-da50-11e1-9b23-aabbccddeeff::urn:schemas-upnp-org:device:basic:1',
      );
      expect(await search('urn:dial-multiscreen-org:service:dial:1'), isEmpty);
    });

    test('by default it is active and announces to the SSDP multicast group', () async {
      final defaults = SsdpResponder(settings: api.settings, location: (_) => 'http://x/description.xml');
      expect(defaults.port, 1900);
      expect(defaults.bindAddress, InternetAddress.anyIPv4);
      expect(defaults.multicastGroup, '239.255.255.250');
      expect(defaults.notifyTo, (InternetAddress('239.255.255.250'), 1900));
      expect(
        SsdpResponder(settings: api.settings, location: (_) => '', multicastGroup: null).notifyTo,
        isNull,
        reason: 'unicast only: nowhere to announce',
      );
      // Without an active check it announces as soon as it starts.
      responder = SsdpResponder(
        settings: api.settings,
        location: (_) => 'http://127.0.0.1:1818/description.xml',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: null,
        notifyTo: (InternetAddress.loopbackIPv4, probe.port),
      );
      await responder.start();
      for (var i = 0; i < 100 && replies.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(replies.map((r) => headers(r)['nts']), everyElement('ssdp:alive'));
    });

    test('a multicast group it cannot join fails start and leaves no socket open', () async {
      responder = SsdpResponder(
        settings: api.settings,
        location: (_) => '',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        // Not a multicast address, so joining fails.
        multicastGroup: '127.0.0.1',
        notifyTo: (InternetAddress.loopbackIPv4, probe.port),
      );
      await expectLater(responder.start(), throwsA(isA<OSError>()));
      expect(responder.boundPort, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(replies, isEmpty, reason: 'nothing announced, so no byebye either');
    });

    test('a failed send is logged, and a new socket takes over and answers', () async {
      final printed = <String>[];
      final savedPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      addTearDown(() => debugPrint = savedPrint);
      responder = SsdpResponder(
        settings: api.settings,
        location: (_) => 'http://127.0.0.1:1818/description.xml',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: null,
        // A socket on loopback cannot reach this documentation address, so
        // every NOTIFY fails with an error from the operating system.
        notifyTo: (InternetAddress('192.0.2.1'), 1900),
        active: () => active,
        reopenDelay: const Duration(milliseconds: 20),
      );
      await responder.start();
      for (var i = 0; i < 100 && printed.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(printed.first, startsWith('SSDP socket error: SocketException: Send failed'));
      // dart:io closes a datagram socket after an error, so the responder
      // has none until it reopens. Kept quiet, the new one's NOTIFY cannot
      // fail in turn.
      expect(responder.boundPort, isNull);
      active = false;
      for (var i = 0; i < 100 && responder.boundPort == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(responder.boundPort, isNotNull);
      active = true;
      expect(await search('upnp:rootdevice'), hasLength(1));
      // The byebye fails too, but after a stop that only logs.
      printed.clear();
      await responder.stop();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(printed, everyElement(startsWith('SSDP socket error:')));
      expect(responder.boundPort, isNull);
    });

    test('stopping while the socket is down cancels the reopen', () async {
      responder = SsdpResponder(
        settings: api.settings,
        location: (_) => '',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: null,
        notifyTo: (InternetAddress('192.0.2.1'), 1900),
        reopenDelay: const Duration(milliseconds: 20),
      );
      final savedPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {};
      addTearDown(() => debugPrint = savedPrint);
      await responder.start();
      for (var i = 0; i < 100 && responder.boundPort != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await responder.stop();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(responder.boundPort, isNull);
    });

    test('a socket that cannot be reopened is logged and stays down', () async {
      final printed = <String>[];
      final savedPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      addTearDown(() => debugPrint = savedPrint);
      // A fixed port, taken by another socket between the failure and the
      // reopen.
      final first = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final fixed = first.port;
      first.close();
      responder = SsdpResponder(
        settings: api.settings,
        location: (_) => '',
        port: fixed,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: null,
        notifyTo: (InternetAddress('192.0.2.1'), 1900),
        reopenDelay: const Duration(milliseconds: 50),
      );
      await responder.start();
      for (var i = 0; i < 100 && responder.boundPort != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final squatter = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, fixed, reuseAddress: false);
      addTearDown(squatter.close);
      for (var i = 0; i < 100 && !printed.any((p) => p.startsWith('SSDP could not reopen')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(printed.last, startsWith('SSDP could not reopen: SocketException'));
      expect(responder.boundPort, isNull);
    });
  });

  group('edge cases', () {
    test('responder errors name a busy port, else the operating system message', () {
      for (final code in [98, 48, 10048]) {
        expect(
          responderError(SocketException('bind', osError: OSError('in use', code)), 1900),
          'the multicast port 1900 is busy',
        );
      }
      expect(
        responderError(SocketException('bind', osError: const OSError('No such device', 19)), 5353),
        'No such device',
      );
      expect(responderError(const SocketException('no network'), 5353), 'no network');
      expect(responderError(StateError('closed'), 5353), 'Bad state: closed');
    });

    test('the app factory serves on the given ports with the real discovery ports', () {
      final nsd = SimulatedSystemMdns();
      final created = BridgeServer.create(api, const [8123], nsd);
      expect(created.ports, [8123]);
      expect(created.nsd, same(nsd));
      expect(created.ssdpPort, 1900);
      expect(created.multicastGroup, '239.255.255.250');
      expect(created.mdnsPort, 5353);
      expect(created.mdnsGroup, '224.0.0.251');
      expect(created.running, isFalse);
      expect(created.error, isNull);
    });

    test('when every port is busy it reports why and does not run', () async {
      final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(blocker.close);
      server = local(ports: [blocker.port, blocker.port]);
      var notified = 0;
      server.addListener(() => notified++);
      await server.start();
      expect(server.running, isFalse);
      expect(server.port, isNull);
      expect(server.error, startsWith('Could not listen on port ${blocker.port} or ${blocker.port}: SocketException'));
      expect(notified, 1);
    });

    test('when the addresses cannot be read it still serves, at loopback', () async {
      server = BridgeServer(
        api,
        ports: const [0],
        ssdpPort: 0,
        multicastGroup: null,
        mdnsPort: 0,
        mdnsGroup: null,
        addresses: () async => throw const SocketException('no interfaces'),
      );
      await server.start();
      expect(server.running, isTrue);
      expect(server.addresses, isEmpty);
      expect(api.ipAddress, '127.0.0.1');
      final response = await http.get(Uri.parse('http://127.0.0.1:${server.port}/api/config'));
      expect(response.statusCode, 200);
    });

    test('switching announcing off silences discovery but keeps HTTP', () async {
      await server.start();
      expect(server.ssdp && server.mdns, isTrue);
      final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(probe.close);
      final replies = <List<int>>[];
      probe.listen((event) {
        if (event != RawSocketEvent.read) return;
        if (probe.receive() case final d?) replies.add(d.data);
      });
      var notified = 0;
      server.addListener(() => notified++);
      api.settings.announce = false;
      await server.announcementChanged();
      expect(notified, 1);
      expect(server.ssdp, isFalse);
      expect(server.mdns, isFalse);
      probe.send(
        utf8.encode('M-SEARCH * HTTP/1.1\r\nMAN: "ssdp:discover"\r\nST: ssdp:all\r\n\r\n'),
        InternetAddress.loopbackIPv4,
        server.boundSsdpPort!,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(replies, isEmpty);
      final response = await http.get(Uri.parse('http://127.0.0.1:${server.port}/api/config'));
      expect(response.statusCode, 200);
    });

    test('a request the API fails on is a 500 that still carries CORS headers', () async {
      final printed = <String>[];
      final savedPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      addTearDown(() => debugPrint = savedPrint);
      server = BridgeServer(
        _FailingApi(home, api.settings),
        ports: const [0],
        ssdpPort: 0,
        multicastGroup: null,
        mdnsPort: 0,
        mdnsGroup: null,
        addresses: loopback,
      );
      await server.start();
      final response = await http.get(Uri.parse('http://127.0.0.1:${server.port}/api/config'));
      expect(response.statusCode, 500);
      expect(response.headers['access-control-allow-origin'], '*');
      expect(printed, contains('Bridge emulator: Bad state: broken'));
    });

    test('clients are given the address on their own subnet', () {
      const addresses = ['10.0.0.5', '192.168.1.20'];
      expect(BridgeServer.hostFor(InternetAddress.loopbackIPv4, addresses), '127.0.0.1');
      expect(BridgeServer.hostFor(InternetAddress('192.168.1.77'), addresses), '192.168.1.20');
      expect(BridgeServer.hostFor(InternetAddress('10.0.0.9'), addresses), '10.0.0.5');
      expect(BridgeServer.hostFor(InternetAddress('172.16.0.3'), addresses), '10.0.0.5', reason: 'best first');
      expect(BridgeServer.hostFor(InternetAddress('172.16.0.3'), const []), '127.0.0.1');
    });

    test('LAN addresses put Wi-Fi first and mobile data last, without loopback or link-local', () {
      final interfaces = [
        _Interface('rmnet0', ['100.64.0.2']),
        _Interface('lo', ['127.0.0.1']),
        _Interface('tun0', ['10.8.0.2']),
        _Interface('dummy0', ['172.20.0.1']),
        _Interface('eth0', ['192.168.2.4', '169.254.3.3']),
        _Interface('enp3s0', ['192.168.3.4']),
        _Interface('wlan0', ['192.168.1.20']),
      ];
      expect(BridgeServer.orderAddresses(interfaces), [
        '192.168.1.20',
        '192.168.2.4',
        '192.168.3.4',
        '172.20.0.1',
        '100.64.0.2',
        '10.8.0.2',
      ]);
    });

    test('the real interface list has no loopback addresses', () async {
      final addresses = await BridgeServer.lanAddresses();
      for (final a in addresses) {
        expect(InternetAddress(a).isLoopback, isFalse, reason: a);
        expect(InternetAddress(a).type, InternetAddressType.IPv4);
      }
    });

    test('the in-process server reports a made-up LAN address and never an error', () async {
      final fake = InProcessEmulatorServer(api, BridgeServer.defaultPorts);
      expect(fake.error, isNull);
      expect(fake.port, isNull);
      expect(fake.ssdp || fake.mdns, isFalse);
      var notified = 0;
      fake.addListener(() => notified++);
      await fake.start();
      expect(fake.addresses, ['192.168.1.50']);
      expect(api.ipAddress, '192.168.1.50');
      expect(fake.port, 1818);
      expect(fake.ssdp && fake.mdns, isTrue);
      expect([fake.error, fake.ssdpError, fake.mdnsError], [null, null, null]);
      api.settings.announce = false;
      await fake.announcementChanged();
      expect(fake.ssdp || fake.mdns, isFalse);
      await fake.stop();
      await fake.stop();
      expect(fake.running, isFalse);
      expect(notified, 3, reason: 'start, announce change and the first stop');
      final fixed = InProcessEmulatorServer(api, const [8123]);
      await fixed.start();
      expect(fixed.port, 8123);
    });
  });
}

class _FailingApi extends BridgeApi {
  _FailingApi(super.home, super.settings);

  @override
  (int, Object) handle(String method, String path, String rawBody, {Map<String, String> headers = const {}}) =>
      throw StateError('broken');
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

/// An interface address with only what the ordering reads.
class _Address implements InterfaceAddress {
  _Address(String address) : _address = InternetAddress(address);

  final InternetAddress _address;

  @override
  String get address => _address.address;

  @override
  bool get isLoopback => _address.isLoopback;

  @override
  bool get isLinkLocal => _address.isLinkLocal;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
