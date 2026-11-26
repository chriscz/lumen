// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// The record types the mDNS responder reads and writes (RFC 1035, 2782).
abstract final class DnsType {
  static const a = 1;
  static const ptr = 12;
  static const txt = 16;
  static const aaaa = 28;
  static const srv = 33;
  static const any = 255;
}

/// Class IN; mDNS uses its top bit for QU in questions and cache-flush in
/// records (RFC 6762 sections 5.4 and 10.2).
const _classIn = 1;
const _topBit = 0x8000;

/// Whether two names are the same, ignoring ASCII case (RFC 6762 section 16).
bool dnsNamesEqual(String a, String b) => a.toLowerCase() == b.toLowerCase();

@immutable
class DnsQuestion {
  const DnsQuestion(this.name, this.type, {this.unicastResponse = false});

  final String name;
  final int type;

  /// The QU bit: the asker wants the answer sent straight back by unicast.
  final bool unicastResponse;

  @override
  bool operator ==(Object other) =>
      other is DnsQuestion && other.name == name && other.type == type && other.unicastResponse == unicastResponse;

  @override
  int get hashCode => Object.hash(name, type, unicastResponse);

  @override
  String toString() => 'DnsQuestion($name, $type${unicastResponse ? ', QU' : ''})';
}

/// What a record says; one subclass per type the responder understands.
@immutable
sealed class DnsData {
  const DnsData();

  int get type;
}

class PtrData extends DnsData {
  const PtrData(this.name);

  final String name;

  @override
  int get type => DnsType.ptr;

  @override
  bool operator ==(Object other) => other is PtrData && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'PTR $name';
}

class SrvData extends DnsData {
  const SrvData({required this.port, required this.target, this.priority = 0, this.weight = 0});

  final int priority;
  final int weight;
  final int port;
  final String target;

  @override
  int get type => DnsType.srv;

  @override
  bool operator ==(Object other) =>
      other is SrvData &&
      other.priority == priority &&
      other.weight == weight &&
      other.port == port &&
      other.target == target;

  @override
  int get hashCode => Object.hash(priority, weight, port, target);

  @override
  String toString() => 'SRV $priority $weight $port $target';
}

class TxtData extends DnsData {
  const TxtData(this.entries);

  /// The `key=value` strings, in order.
  final List<String> entries;

  @override
  int get type => DnsType.txt;

  @override
  bool operator ==(Object other) => other is TxtData && listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hashAll(entries);

  @override
  String toString() => 'TXT $entries';
}

class AData extends DnsData {
  const AData(this.address);

  /// Dotted IPv4, such as `192.168.1.20`.
  final String address;

  @override
  int get type => DnsType.a;

  @override
  bool operator ==(Object other) => other is AData && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => 'A $address';
}

/// Any other type, kept as its bytes.
class RawData extends DnsData {
  const RawData(this.type, this.bytes);

  @override
  final int type;
  final List<int> bytes;

  @override
  bool operator ==(Object other) => other is RawData && other.type == type && listEquals(other.bytes, bytes);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(bytes));

  @override
  String toString() => 'RAW $type $bytes';
}

@immutable
class DnsRecord {
  const DnsRecord(this.name, {required this.ttl, required this.data, this.cacheFlush = false});

  final String name;

  /// Seconds; 0 says goodbye (RFC 6762 section 10.1).
  final int ttl;

  /// Set on unique records so caches drop older copies (RFC 6762 section 10.2).
  final bool cacheFlush;
  final DnsData data;

  int get type => data.type;

  DnsRecord withTtl(int ttl, {bool? cacheFlush}) =>
      DnsRecord(name, ttl: ttl, data: data, cacheFlush: cacheFlush ?? this.cacheFlush);

  @override
  bool operator ==(Object other) =>
      other is DnsRecord &&
      other.name == name &&
      other.ttl == ttl &&
      other.cacheFlush == cacheFlush &&
      other.data == data;

  @override
  int get hashCode => Object.hash(name, ttl, cacheFlush, data);

  @override
  String toString() => 'DnsRecord($name, ttl $ttl${cacheFlush ? ', flush' : ''}, $data)';
}

/// A DNS message (RFC 1035 section 4) as mDNS uses it. Names are written
/// whole and read with compression pointers followed.
@immutable
class DnsMessage {
  const DnsMessage({
    this.id = 0,
    this.isResponse = false,
    bool? authoritative,
    this.questions = const [],
    this.answers = const [],
    this.authorities = const [],
    this.additionals = const [],
  }) : authoritative = authoritative ?? isResponse;

  final int id;
  final bool isResponse;

  /// The AA bit; mDNS responses always set it (RFC 6762 section 18.4).
  final bool authoritative;
  final List<DnsQuestion> questions;
  final List<DnsRecord> answers;
  final List<DnsRecord> authorities;
  final List<DnsRecord> additionals;

  Uint8List encode() {
    final out = BytesBuilder();
    void u16(int v) => out.add([v >> 8 & 0xff, v & 0xff]);
    void u32(int v) => out.add([v >> 24 & 0xff, v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff]);
    u16(id);
    u16((isResponse ? 0x8000 : 0) | (authoritative ? 0x0400 : 0));
    for (final section in [questions, answers, authorities, additionals]) {
      u16(section.length);
    }
    for (final q in questions) {
      out.add(_name(q.name));
      u16(q.type);
      u16(_classIn | (q.unicastResponse ? _topBit : 0));
    }
    for (final r in [...answers, ...authorities, ...additionals]) {
      out.add(_name(r.name));
      u16(r.type);
      u16(_classIn | (r.cacheFlush ? _topBit : 0));
      u32(r.ttl);
      final data = _rdata(r.data);
      u16(data.length);
      out.add(data);
    }
    return out.takeBytes();
  }

  static List<int> _name(String name) {
    final out = <int>[];
    for (final label in name.split('.').where((l) => l.isNotEmpty)) {
      final bytes = utf8.encode(label);
      if (bytes.length > 63) throw ArgumentError.value(name, 'name', 'has a label longer than 63 bytes');
      out
        ..add(bytes.length)
        ..addAll(bytes);
    }
    return out..add(0);
  }

  static List<int> _rdata(DnsData data) => switch (data) {
    PtrData(:final name) => _name(name),
    SrvData(:final priority, :final weight, :final port, :final target) => [
      priority >> 8 & 0xff,
      priority & 0xff,
      weight >> 8 & 0xff,
      weight & 0xff,
      port >> 8 & 0xff,
      port & 0xff,
      ..._name(target),
    ],
    TxtData(:final entries) when entries.isEmpty => const [0],
    TxtData(:final entries) => [for (final e in entries) ..._string(e)],
    AData(:final address) => [for (final part in address.split('.')) int.parse(part)],
    RawData(:final bytes) => bytes,
  };

  /// A length-prefixed character string (RFC 1035 section 3.3).
  static List<int> _string(String s) {
    final bytes = utf8.encode(s);
    if (bytes.length > 255) throw ArgumentError.value(s, 'string', 'is longer than 255 bytes');
    return [bytes.length, ...bytes];
  }

  /// Reads a message; throws [FormatException] when it is malformed.
  static DnsMessage decode(List<int> bytes) => _Reader(bytes is Uint8List ? bytes : Uint8List.fromList(bytes)).read();

  @override
  String toString() =>
      'DnsMessage(id $id${isResponse ? ', response' : ''}, q $questions, an $answers, ns $authorities, ar $additionals)';
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  var _at = 0;

  Never _bad(String why) => throw FormatException('Malformed DNS message: $why', bytes, _at);

  void _need(int n, [int? from]) {
    if ((from ?? _at) + n > bytes.length) _bad('truncated');
  }

  int _u8() {
    _need(1);
    return bytes[_at++];
  }

  int _u16() {
    _need(2);
    final v = bytes[_at] << 8 | bytes[_at + 1];
    _at += 2;
    return v;
  }

  int _u32() => _u16() << 16 | _u16();

  /// Reads a name at the cursor, following compression pointers.
  String _name() {
    final labels = <String>[];
    var at = _at;
    int? resume;
    var jumps = 0;
    while (true) {
      _need(1, at);
      final len = bytes[at];
      if (len == 0) {
        at++;
        break;
      }
      if (len & 0xc0 == 0xc0) {
        _need(2, at);
        if (++jumps > 32) _bad('compression loop');
        resume ??= at + 2;
        at = (len & 0x3f) << 8 | bytes[at + 1];
        continue;
      }
      if (len & 0xc0 != 0) _bad('unknown label type');
      _need(1 + len, at);
      labels.add(utf8.decode(bytes.sublist(at + 1, at + 1 + len), allowMalformed: true));
      at += 1 + len;
    }
    _at = resume ?? at;
    return labels.join('.');
  }

  DnsRecord _record() {
    final name = _name();
    final type = _u16();
    final cls = _u16();
    final ttl = _u32();
    final length = _u16();
    _need(length);
    final end = _at + length;
    final DnsData data;
    switch (type) {
      case DnsType.ptr:
        data = PtrData(_name());
      case DnsType.srv:
        final priority = _u16(), weight = _u16(), port = _u16();
        data = SrvData(priority: priority, weight: weight, port: port, target: _name());
      case DnsType.txt:
        final entries = <String>[];
        while (_at < end) {
          final n = _u8();
          _need(n);
          if (n > 0) entries.add(utf8.decode(bytes.sublist(_at, _at + n), allowMalformed: true));
          _at += n;
        }
        data = TxtData(entries);
      case DnsType.a when length == 4:
        data = AData(bytes.sublist(_at, end).join('.'));
      default:
        data = RawData(type, bytes.sublist(_at, end));
    }
    if (_at > end) _bad('record data overruns its length');
    _at = end;
    return DnsRecord(name, ttl: ttl, data: data, cacheFlush: cls & _topBit != 0);
  }

  DnsMessage read() {
    final id = _u16();
    final flags = _u16();
    final counts = [_u16(), _u16(), _u16(), _u16()];
    final questions = [
      for (var i = 0; i < counts[0]; i++)
        (() {
          final name = _name();
          final type = _u16();
          final cls = _u16();
          return DnsQuestion(name, type, unicastResponse: cls & _topBit != 0);
        })(),
    ];
    List<DnsRecord> records(int n) => [for (var i = 0; i < n; i++) _record()];
    return DnsMessage(
      id: id,
      isResponse: flags & 0x8000 != 0,
      authoritative: flags & 0x0400 != 0,
      questions: questions,
      answers: records(counts[1]),
      authorities: records(counts[2]),
      additionals: records(counts[3]),
    );
  }
}
