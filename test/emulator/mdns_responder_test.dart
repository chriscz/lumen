// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/dns_message.dart';
import 'package:lumen/emulator/emulator_settings.dart';
import 'package:lumen/emulator/mdns_responder.dart';

void main() {
  final settings = EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff', name: 'Lumen');
  const instance = 'Lumen-DDEEFF._hue._tcp.local';

  group('records', () {
    final responder = MdnsResponder.forBridge(settings, httpPort: 1818, address: '192.168.1.20');

    test('name the instance after the bridge and the end of its id', () {
      expect(responder.instance, instance);
      expect(responder.host, 'lumen-ddeeff.local');
    });

    test('a hostname is a safe label even for an odd bridge name', () {
      final odd = MdnsResponder.forBridge(
        EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff', name: 'Living room.v2 ✨'),
        httpPort: 80,
        address: '10.0.0.2',
      );
      expect(odd.host, 'living-room-v2-ddeeff.local');
      expect(odd.instance, 'Living room-v2 ✨-DDEEFF._hue._tcp.local');
    });

    test('a PTR query for _hue._tcp gets PTR, with SRV, TXT and A alongside', () {
      final reply = responder.respond(
        const DnsMessage(questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr)]),
        legacy: false,
      )!;
      expect(reply.isResponse, isTrue);
      expect(reply.authoritative, isTrue);
      expect(reply.questions, isEmpty);
      expect(reply.answers, const [DnsRecord('_hue._tcp.local', ttl: 4500, data: PtrData(instance))]);
      expect(reply.additionals, const [
        DnsRecord(instance, ttl: 120, cacheFlush: true, data: SrvData(port: 1818, target: 'lumen-ddeeff.local')),
        DnsRecord(
          instance,
          ttl: 4500,
          cacheFlush: true,
          data: TxtData(['bridgeid=aabbccfffeddeeff', 'modelid=BSB002']),
        ),
        DnsRecord('lumen-ddeeff.local', ttl: 120, cacheFlush: true, data: AData('192.168.1.20')),
      ]);
    });

    test('a service enumeration query gets a PTR to _hue._tcp', () {
      final reply = responder.respond(
        const DnsMessage(questions: [DnsQuestion('_services._dns-sd._udp.local', DnsType.ptr)]),
        legacy: false,
      )!;
      expect(reply.answers, const [
        DnsRecord('_services._dns-sd._udp.local', ttl: 4500, data: PtrData('_hue._tcp.local')),
      ]);
    });

    test('SRV, TXT, A and ANY questions for its own names are answered', () {
      DnsMessage? ask(String name, int type) =>
          responder.respond(DnsMessage(questions: [DnsQuestion(name, type)]), legacy: false);
      expect(ask(instance, DnsType.srv)!.answers.single.data, isA<SrvData>());
      expect(ask(instance.toUpperCase(), DnsType.txt)!.answers.single.data, isA<TxtData>());
      expect(ask('lumen-ddeeff.local', DnsType.a)!.answers.single.data, const AData('192.168.1.20'));
      expect(ask(instance, DnsType.any)!.answers.map((r) => r.type), [DnsType.srv, DnsType.txt]);
    });

    test('other questions, responses and known answers get nothing', () {
      expect(
        responder.respond(
          const DnsMessage(questions: [DnsQuestion('_googlecast._tcp.local', DnsType.ptr)]),
          legacy: false,
        ),
        isNull,
      );
      expect(
        responder.respond(
          const DnsMessage(isResponse: true, questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr)]),
          legacy: false,
        ),
        isNull,
      );
      expect(
        responder.respond(
          const DnsMessage(
            questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr)],
            answers: [DnsRecord('_hue._tcp.local', ttl: 4500, data: PtrData(instance))],
          ),
          legacy: false,
        ),
        isNull,
        reason: 'the asker already knows the answer (RFC 6762 section 7.1)',
      );
    });

    test('a legacy unicast reply echoes the id and question, with short TTLs and no cache flush', () {
      const question = DnsQuestion('_hue._tcp.local', DnsType.ptr);
      final reply = responder.respond(const DnsMessage(id: 4242, questions: [question]), legacy: true)!;
      expect(reply.id, 4242);
      expect(reply.questions, const [question]);
      for (final r in [...reply.answers, ...reply.additionals]) {
        expect(r.ttl, lessThanOrEqualTo(10));
        expect(r.cacheFlush, isFalse);
      }
    });

    test('a goodbye carries every record with TTL 0', () {
      final bye = responder.goodbyeMessage();
      expect(bye.isResponse, isTrue);
      expect(bye.answers.map((r) => r.type), [DnsType.ptr, DnsType.srv, DnsType.txt, DnsType.a]);
      expect(bye.answers.every((r) => r.ttl == 0), isTrue);
    });
  });

  group('over loopback', () {
    late RawDatagramSocket probe;
    late MdnsResponder responder;
    final received = <(DnsMessage, int)>[];
    var active = true;

    setUp(() async {
      received.clear();
      active = true;
      probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      probe.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = probe.receive();
        if (datagram != null) received.add((DnsMessage.decode(datagram.data), datagram.port));
      });
      responder = MdnsResponder.forBridge(
        settings,
        httpPort: 1818,
        address: '127.0.0.1',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: null,
        announceTo: (InternetAddress.loopbackIPv4, probe.port),
        announceGap: const Duration(milliseconds: 30),
        active: () => active,
      );
    });

    tearDown(() async {
      await responder.stop();
      probe.close();
    });

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 200 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));

    test('answers a QU PTR query by unicast with PTR, SRV, TXT and A', () async {
      await responder.start();
      await settle();
      received.clear();
      probe.send(
        const DnsMessage(questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr, unicastResponse: true)]).encode(),
        InternetAddress.loopbackIPv4,
        responder.boundPort!,
      );
      await until(() => received.isNotEmpty);
      final (reply, from) = received.single;
      expect(from, responder.boundPort);
      final records = [...reply.answers, ...reply.additionals];
      expect((records.firstWhere((r) => r.type == DnsType.ptr).data as PtrData).name, instance);
      final srv = records.firstWhere((r) => r.type == DnsType.srv).data as SrvData;
      expect(srv.port, 1818);
      expect(srv.target, 'lumen-ddeeff.local');
      expect((records.firstWhere((r) => r.type == DnsType.txt).data as TxtData).entries, [
        'bridgeid=aabbccfffeddeeff',
        'modelid=BSB002',
      ]);
      expect(records.firstWhere((r) => r.type == DnsType.a).data, const AData('127.0.0.1'));
    });

    test('announces three times on start, then says goodbye on stop', () async {
      await responder.start();
      await until(() => received.length >= 3);
      await settle();
      expect(received, hasLength(3));
      for (final (message, _) in received) {
        expect(message.isResponse, isTrue);
        expect(message.answers.map((r) => r.type), [DnsType.ptr, DnsType.srv, DnsType.txt, DnsType.a]);
        expect(message.answers.every((r) => r.ttl > 0), isTrue);
      }
      received.clear();
      await responder.stop();
      await until(() => received.isNotEmpty);
      expect(received.single.$1.answers, hasLength(4));
      expect(received.single.$1.answers.every((r) => r.ttl == 0), isTrue);
    });

    test('while inactive it neither announces nor answers, and stopping sends no goodbye', () async {
      active = false;
      await responder.start();
      probe.send(
        const DnsMessage(questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr, unicastResponse: true)]).encode(),
        InternetAddress.loopbackIPv4,
        responder.boundPort!,
      );
      await settle();
      await responder.stop();
      await settle();
      expect(received, isEmpty);
    });

    test('going inactive says goodbye and going active announces again', () async {
      await responder.start();
      await until(() => received.length >= 3);
      received.clear();
      active = false;
      responder.goodbye();
      await until(() => received.isNotEmpty);
      expect(received.single.$1.answers.every((r) => r.ttl == 0), isTrue);
      received.clear();
      active = true;
      responder.announce();
      await until(() => received.isNotEmpty);
      expect(received.first.$1.answers.every((r) => r.ttl > 0), isTrue);
    });

    test('ignores garbage', () async {
      await responder.start();
      await until(() => received.length >= 3);
      received.clear();
      probe.send([1, 2, 3], InternetAddress.loopbackIPv4, responder.boundPort!);
      await settle();
      expect(received, isEmpty);
    });

    group('a full mDNS querier on port 5353', () {
      late RawDatagramSocket querier;
      final unicast = <DnsMessage>[];

      setUp(() async {
        unicast.clear();
        // Shared, as system mDNS daemons share it, so this binds beside them.
        querier = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          MdnsResponder.mdnsPort,
          reuseAddress: true,
          reusePort: true,
        );
        querier.listen((event) {
          if (event != RawSocketEvent.read) return;
          if (querier.receive() case final d?) unicast.add(DnsMessage.decode(d.data));
        });
        await responder.start();
        await until(() => received.length >= 3);
        received.clear();
      });

      tearDown(() => querier.close());

      test('gets a QM answer on the multicast group, with full TTLs', () async {
        querier.send(
          const DnsMessage(id: 9, questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr)]).encode(),
          InternetAddress.loopbackIPv4,
          responder.boundPort!,
        );
        await until(() => received.isNotEmpty);
        await settle();
        final reply = received.single.$1;
        expect(reply.id, 0, reason: 'a multicast reply does not echo the id');
        expect(reply.questions, isEmpty);
        expect(reply.answers.single.ttl, MdnsResponder.otherTtl);
        expect(reply.additionals.firstWhere((r) => r.type == DnsType.srv).cacheFlush, isTrue);
        expect(unicast, isEmpty);
      });

      test('gets a QU answer straight back', () async {
        querier.send(
          const DnsMessage(questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr, unicastResponse: true)]).encode(),
          InternetAddress.loopbackIPv4,
          responder.boundPort!,
        );
        await until(() => unicast.isNotEmpty);
        await settle();
        expect(unicast.single.answers.single.ttl, MdnsResponder.otherTtl);
        expect(received, isEmpty);
      });
    });

    test('a failed send is logged, and a new socket takes over and announces', () async {
      final printed = <String>[];
      final savedPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      addTearDown(() => debugPrint = savedPrint);
      responder = MdnsResponder(
        instance: instance,
        host: 'lumen-ddeeff.local',
        httpPort: 1818,
        address: '127.0.0.1',
        txt: const ['bridgeid=aabbccfffeddeeff'],
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: null,
        // A socket on loopback cannot reach this documentation address.
        announceTo: (InternetAddress('192.0.2.1'), 5353),
        announceGap: const Duration(milliseconds: 30),
        active: () => active,
        reopenDelay: const Duration(milliseconds: 20),
      );
      await responder.start();
      await until(() => printed.isNotEmpty);
      expect(printed.first, startsWith('mDNS socket error: SocketException: Send failed'));
      expect(responder.boundPort, isNull, reason: 'dart:io closed the socket');
      // Quiet, the new socket does not fail in turn and can be asked.
      active = false;
      await until(() => responder.boundPort != null);
      expect(responder.boundPort, isNotNull);
      active = true;
      received.clear();
      probe.send(
        const DnsMessage(questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr, unicastResponse: true)]).encode(),
        InternetAddress.loopbackIPv4,
        responder.boundPort!,
      );
      await until(() => received.isNotEmpty);
      expect(received.single.$1.answers.single.data, const PtrData(instance));
      // The goodbye fails too, but after a stop that only logs.
      printed.clear();
      await responder.stop();
      await settle();
      expect(printed, everyElement(startsWith('mDNS socket error:')));
      expect(responder.boundPort, isNull);
    });

    test('stopping while the socket is down cancels the reopen', () async {
      final savedPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {};
      addTearDown(() => debugPrint = savedPrint);
      responder = MdnsResponder.forBridge(
        settings,
        httpPort: 1818,
        address: '127.0.0.1',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: null,
        announceTo: (InternetAddress('192.0.2.1'), 5353),
        reopenDelay: const Duration(milliseconds: 20),
      );
      await responder.start();
      await until(() => responder.boundPort == null);
      await responder.stop();
      await settle();
      expect(responder.boundPort, isNull);
    });

    test('a socket that cannot be reopened is logged and stays down', () async {
      final printed = <String>[];
      final savedPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      addTearDown(() => debugPrint = savedPrint);
      // The fallback bind fails once the first socket is gone, as when
      // another app takes the port without sharing it.
      var binds = 0;
      responder = MdnsResponder.forBridge(
        settings,
        httpPort: 1818,
        address: '127.0.0.1',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: null,
        announceTo: (InternetAddress('192.0.2.1'), 5353),
        reopenDelay: const Duration(milliseconds: 20),
        bind: (host, port, {reuseAddress = true, reusePort = false, ttl = 1}) async {
          if (binds++ > 0) throw const SocketException('port taken');
          return RawDatagramSocket.bind(host, port, reuseAddress: reuseAddress, reusePort: reusePort);
        },
      );
      await responder.start();
      await until(() => printed.any((p) => p.startsWith('mDNS could not reopen')));
      expect(printed.last, 'mDNS could not reopen: SocketException: port taken');
      expect(responder.boundPort, isNull);
    });

    test('where reusePort is unsupported it binds without it', () async {
      final calls = <bool>[];
      responder = MdnsResponder.forBridge(
        settings,
        httpPort: 1818,
        address: '127.0.0.1',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: null,
        announceTo: (InternetAddress.loopbackIPv4, probe.port),
        bind: (host, port, {reuseAddress = true, reusePort = false, ttl = 1}) async {
          calls.add(reusePort);
          // As on Windows.
          if (reusePort) throw UnsupportedError('reusePort');
          return RawDatagramSocket.bind(host, port, reuseAddress: reuseAddress);
        },
      );
      await responder.start();
      expect(calls, [true, false]);
      await until(() => received.isNotEmpty);
      expect(received.first.$1.answers, hasLength(4));
    });

    test('by default it is active and announces to the mDNS multicast group', () async {
      MdnsResponder build({String? group = MdnsResponder.mdnsGroup, (InternetAddress, int)? to}) => MdnsResponder(
        instance: instance,
        host: 'lumen-ddeeff.local',
        httpPort: 1818,
        address: '127.0.0.1',
        txt: const [],
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        multicastGroup: group,
        announceTo: to,
      );
      expect(build().announceTo, (InternetAddress('224.0.0.251'), 5353));
      expect(build(group: null).announceTo, isNull);
      responder = build(group: null, to: (InternetAddress.loopbackIPv4, probe.port));
      await responder.start();
      await until(() => received.isNotEmpty);
      expect(received.first.$1.answers, hasLength(4));
    });

    test('a multicast group it cannot join fails start and leaves no socket open', () async {
      responder = MdnsResponder.forBridge(
        settings,
        httpPort: 1818,
        address: '127.0.0.1',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        // Not a multicast address, so joining fails.
        multicastGroup: '127.0.0.1',
        announceTo: (InternetAddress.loopbackIPv4, probe.port),
      );
      await expectLater(responder.start(), throwsA(isA<OSError>()));
      expect(responder.boundPort, isNull);
      await settle();
      expect(received, isEmpty);
    });
  });

  test('start fails when the port is held without sharing', () async {
    final blocker = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0, reuseAddress: false);
    addTearDown(blocker.close);
    final responder = MdnsResponder.forBridge(
      settings,
      httpPort: 1818,
      address: '127.0.0.1',
      port: blocker.port,
      bindAddress: InternetAddress.loopbackIPv4,
      multicastGroup: null,
    );
    await expectLater(responder.start(), throwsA(isA<SocketException>()));
    await responder.stop();
  });
}
