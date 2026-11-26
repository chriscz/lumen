// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/dns_message.dart';

/// A name in wire format, without compression.
List<int> name(String dotted) => [
  for (final label in dotted.split('.')) ...[label.length, ...label.codeUnits],
  0,
];

List<int> u16(int v) => [v >> 8 & 0xff, v & 0xff];

List<int> u32(int v) => [v >> 24 & 0xff, v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff];

void main() {
  test('a query round trips, keeping the unicast-response bit', () {
    final query = DnsMessage(
      id: 0,
      questions: [
        const DnsQuestion('_hue._tcp.local', DnsType.ptr, unicastResponse: true),
        const DnsQuestion('_services._dns-sd._udp.local', DnsType.ptr),
      ],
    );
    final decoded = DnsMessage.decode(query.encode());
    expect(decoded.isResponse, isFalse);
    expect(decoded.questions, query.questions);
    expect(decoded.questions.first.unicastResponse, isTrue);
    expect(decoded.questions.last.unicastResponse, isFalse);
  });

  test('a response with PTR, SRV, TXT and A records round trips', () {
    final response = DnsMessage(
      id: 7,
      isResponse: true,
      answers: [const DnsRecord('_hue._tcp.local', ttl: 4500, data: PtrData('Lumen-DDEEFF._hue._tcp.local'))],
      additionals: [
        const DnsRecord(
          'Lumen-DDEEFF._hue._tcp.local',
          ttl: 120,
          cacheFlush: true,
          data: SrvData(port: 1818, target: 'lumen-ddeeff.local'),
        ),
        const DnsRecord(
          'Lumen-DDEEFF._hue._tcp.local',
          ttl: 4500,
          cacheFlush: true,
          data: TxtData(['bridgeid=aabbccfffeddeeff', 'modelid=BSB002']),
        ),
        const DnsRecord('lumen-ddeeff.local', ttl: 120, cacheFlush: true, data: AData('192.168.1.20')),
      ],
    );
    final decoded = DnsMessage.decode(response.encode());
    expect(decoded.id, 7);
    expect(decoded.isResponse, isTrue);
    expect(decoded.authoritative, isTrue);
    expect(decoded.answers, response.answers);
    expect(decoded.additionals, response.additionals);
    expect(decoded.additionals.first.type, DnsType.srv);
    expect(decoded.additionals.first.cacheFlush, isTrue);
  });

  test('an empty TXT record is a single zero byte and reads back empty', () {
    final bytes = const DnsMessage(
      isResponse: true,
      answers: [DnsRecord('x.local', ttl: 1, data: TxtData([]))],
    ).encode();
    expect(bytes.sublist(bytes.length - 3), [0, 1, 0]);
    expect((DnsMessage.decode(bytes).answers.single.data as TxtData).entries, isEmpty);
  });

  test('unknown record types keep their bytes', () {
    const record = DnsRecord('x.local', ttl: 5, data: RawData(DnsType.aaaa, [1, 2, 3, 4]));
    final decoded = DnsMessage.decode(const DnsMessage(isResponse: true, answers: [record]).encode());
    expect(decoded.answers.single, record);
    expect(decoded.answers.single.type, DnsType.aaaa);
  });

  test('parses a captured browse for _hue._tcp with compressed names', () {
    // A query as sent by `dns-sd -B _hue._tcp` (RFC 6762 section 18): id 0,
    // no flags, two questions and one known answer. The second question and
    // the answer point back at "_tcp.local" and "_hue._tcp.local" with
    // compression pointers (RFC 1035 section 4.1.4).
    final bytes = Uint8List.fromList([
      ...u16(0), ...u16(0), ...u16(2), ...u16(1), ...u16(0), ...u16(0),
      // Offset 12: _hue._tcp.local PTR, class IN with the QU bit.
      ...name('_hue._tcp.local'), ...u16(12), ...u16(0x8001),
      // Offset 33: _services._dns-sd._udp.local PTR, QM.
      ...name('_services._dns-sd._udp.local'), ...u16(12), ...u16(1),
      // Known answer: name is a pointer to offset 12.
      0xc0, 12, ...u16(12), ...u16(1), ...u32(4500),
      // RDATA: "Philips Hue - 685630" then a pointer to offset 12.
      ...u16(23), 20, ...'Philips Hue - 685630'.codeUnits, 0xc0, 12,
    ]);
    final query = DnsMessage.decode(bytes);
    expect(query.isResponse, isFalse);
    expect(query.questions, const [
      DnsQuestion('_hue._tcp.local', DnsType.ptr, unicastResponse: true),
      DnsQuestion('_services._dns-sd._udp.local', DnsType.ptr),
    ]);
    expect(query.answers.single.name, '_hue._tcp.local');
    expect(query.answers.single.ttl, 4500);
    expect((query.answers.single.data as PtrData).name, 'Philips Hue - 685630._hue._tcp.local');
  });

  test('rejects a pointer loop and a truncated message', () {
    final loop = Uint8List.fromList([...u16(0), ...u16(0), ...u16(1), ...u16(0), ...u16(0), ...u16(0), 0xc0, 12]);
    expect(() => DnsMessage.decode(loop), throwsFormatException);
    final full = const DnsMessage(questions: [DnsQuestion('_hue._tcp.local', DnsType.ptr)]).encode();
    expect(() => DnsMessage.decode(full.sublist(0, full.length - 2)), throwsFormatException);
    expect(() => DnsMessage.decode(Uint8List(5)), throwsFormatException);
  });

  test('labels longer than 63 bytes are refused when encoding', () {
    final long = DnsMessage(questions: [DnsQuestion('${'a' * 64}.local', DnsType.a)]);
    expect(long.encode, throwsArgumentError);
  });

  test('TXT strings longer than 255 bytes are refused when encoding', () {
    final long = DnsMessage(
      isResponse: true,
      answers: [
        DnsRecord('x.local', ttl: 1, data: TxtData(['k=${'v' * 254}'])),
      ],
    );
    expect(long.encode, throwsArgumentError);
  });

  test('names compare without regard to case', () {
    expect(dnsNamesEqual('_HUE._tcp.Local', '_hue._tcp.local'), isTrue);
    expect(dnsNamesEqual('_hue._tcp.local', '_hue._udp.local'), isFalse);
  });

  group('values', () {
    // Two separately built copies of every kind of value, and one that
    // differs, so equality cannot lean on identity.
    List<Object> build(String suffix) => [
      DnsQuestion('a$suffix.local', DnsType.ptr, unicastResponse: true),
      PtrData('b$suffix.local'),
      SrvData(port: 80, target: 'c$suffix.local', priority: 1, weight: 2),
      TxtData(['k=$suffix']),
      AData('10.0.0.${suffix.length}'),
      RawData(DnsType.aaaa, [suffix.length]),
      DnsRecord('d$suffix.local', ttl: 9, cacheFlush: true, data: PtrData('e$suffix.local')),
    ];

    test('equal values have equal hash codes, so they work as set keys', () {
      final first = build('x');
      final second = build('x');
      final other = build('yy');
      for (var i = 0; i < first.length; i++) {
        expect(first[i], second[i]);
        expect(first[i].hashCode, second[i].hashCode, reason: '${first[i].runtimeType}');
        expect(first[i], isNot(other[i]));
      }
      expect({...first, ...second}, hasLength(first.length));
    });

    test('values describe themselves for logs and test failures', () {
      final [question, ptr, srv, txt, a, raw, record] = build('x');
      expect('$question', 'DnsQuestion(ax.local, 12, QU)');
      expect('${const DnsQuestion('q.local', DnsType.a)}', 'DnsQuestion(q.local, 1)');
      expect('$ptr', 'PTR bx.local');
      expect('$srv', 'SRV 1 2 80 cx.local');
      expect('$txt', 'TXT [k=x]');
      expect('$a', 'A 10.0.0.1');
      expect('$raw', 'RAW 28 [1]');
      expect('$record', 'DnsRecord(dx.local, ttl 9, flush, PTR ex.local)');
      expect('${const DnsRecord('n.local', ttl: 0, data: AData('1.2.3.4'))}', 'DnsRecord(n.local, ttl 0, A 1.2.3.4)');
      final message = DnsMessage(id: 4, isResponse: true, answers: [record as DnsRecord]);
      expect('$message', 'DnsMessage(id 4, response, q [], an [$record], ns [], ar [])');
      expect(
        '${const DnsMessage(questions: [DnsQuestion('q.local', DnsType.a)])}',
        'DnsMessage(id 0, q [DnsQuestion(q.local, 1)], an [], ns [], ar [])',
      );
    });
  });
}
