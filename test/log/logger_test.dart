// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/log/logger.dart';

void main() {
  late Directory dir;
  var now = DateTime(2026, 10, 23, 14, 0, 0, 123);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lumen-log-test');
    now = DateTime(2026, 10, 23, 14, 0, 0, 123);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Logger open({int segmentBytes = 1024 * 1024}) =>
      Logger(directory: dir, persist: true, segmentBytes: segmentBytes, clock: () => now);

  Logger transient({int keptLines = 3}) => Logger(directory: dir, keptLines: keptLines, clock: () => now);

  group('without persist', () {
    test('keeps only the last few lines on disk', () {
      final log = transient();
      for (var i = 0; i < 10; i++) {
        log
          ..info(LogTag.app, 'line $i')
          ..flush();
      }
      final lines = log.readAll().trimRight().split('\n');
      expect(lines, hasLength(3));
      expect(lines.last, endsWith('line 9'));
      expect(log.files, hasLength(1));
      expect(log.totalBytes, log.files.single.lengthSync());
    });

    test('is off by default', () => expect(Logger(directory: dir).persist, isFalse));

    test('remembers the choice in the log directory', () {
      open();
      expect(Logger(directory: dir).persist, isTrue);
      Logger(directory: dir).persist = false;
      expect(Logger(directory: dir).persist, isFalse);
    });

    test('trims what an earlier persisted run left when persist is now off', () {
      final before = open(segmentBytes: 60);
      for (var i = 0; i < 10; i++) {
        before
          ..info(LogTag.app, 'old $i')
          ..flush();
      }
      final log = Logger(directory: dir, persist: false, keptLines: 2, clock: () => now);
      expect(log.files, hasLength(1));
      expect(log.readAll().trimRight().split('\n'), hasLength(2));
      expect(log.readAll(), contains('old 9'));
    });

    test('switching persist off trims the files at once', () {
      final log = open(segmentBytes: 60);
      for (var i = 0; i < 10; i++) {
        log
          ..info(LogTag.app, 'entry $i')
          ..flush();
      }
      log.keptLines = 2;
      log.persist = false;
      expect(log.files, hasLength(1));
      expect(log.readAll().trimRight().split('\n'), hasLength(2));
    });

    test('a file that cannot be written leaves the entries in memory', () {
      final file = File('${dir.path}/blocker')..writeAsStringSync('x');
      final log = Logger(directory: Directory('${file.path}/logs'), clock: () => now);
      log
        ..info(LogTag.app, 'kept in memory')
        ..flush();
      expect(log.entries.single.message, 'kept in memory');
      expect(log.files, isEmpty);
    });
  });

  test('keeps 100 lines without persist and 1 MB segments with it by default', () {
    final log = Logger(directory: dir);
    expect(log.keptLines, 100);
    expect(log.segmentBytes, 1024 * 1024);
  });

  test('keeps info and above by default and drops debug', () {
    final log = Logger.memory();
    log.debug(LogTag.ble, () => 'advert');
    log.info(LogTag.ble, 'scan started');
    log.warning(LogTag.bridge, 'slow');
    log.error(LogTag.app, 'boom');
    expect(log.entries.map((e) => e.level), [LogLevel.info, LogLevel.warning, LogLevel.error]);
  });

  test('keeps debug entries when debug logging is on', () {
    final log = Logger.memory()..debugEnabled = true;
    log.debug(LogTag.ble, () => 'advert aa:bb');
    expect(log.entries.single.level, LogLevel.debug);
    expect(log.entries.single.message, 'advert aa:bb');
  });

  test('formats each entry with a timestamp, level and tag', () {
    final log = Logger.memory(clock: () => now);
    log.warning(LogTag.bridge, 'HTTP 500');
    expect(log.entries.single.format(), '2026-10-23 14:00:00.123 W bridge     HTTP 500');
  });

  test('writes entries in batches, only on flush', () {
    final log = open();
    log.info(LogTag.app, 'one');
    log.info(LogTag.app, 'two');
    expect(log.readAll(), isEmpty);
    log.flush();
    expect(log.readAll(), contains('one'));
    expect(log.readAll(), contains('two'));
  });

  test('flushes on its own after a short delay', () async {
    final log = Logger(directory: dir, flushInterval: const Duration(milliseconds: 10));
    log.info(LogTag.app, 'later');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(log.readAll(), contains('later'));
  });

  test('a new logger on the same directory appends to the old log and shows it', () {
    open()
      ..info(LogTag.app, 'first run')
      ..flush();
    final second = open()..info(LogTag.app, 'second run');
    second.flush();
    final text = second.readAll();
    expect(text.indexOf('first run'), lessThan(text.indexOf('second run')));
    expect(second.entries.map((e) => e.message), ['first run', 'second run']);
  });

  test('starts a new file at the segment size and never drops old entries', () {
    final log = open(segmentBytes: 200);
    for (var i = 0; i < 20; i++) {
      log.info(LogTag.ble, 'entry number $i with some padding to fill the file');
      log.flush();
    }
    expect(log.files.length, greaterThan(3));
    final text = log.readAll();
    for (var i = 0; i < 20; i++) {
      expect(text, contains('entry number $i '));
    }
    expect(log.totalBytes, text.length);
  });

  test('clear removes every file and entry', () {
    final log = open(segmentBytes: 200);
    for (var i = 0; i < 10; i++) {
      log.info(LogTag.ble, 'entry number $i with some padding to fill the file');
      log.flush();
    }
    log.clear();
    expect(log.entries, isEmpty);
    expect(log.readAll(), isEmpty);
    expect(log.totalBytes, 0);
    log
      ..info(LogTag.app, 'after clear')
      ..flush();
    expect(log.readAll(), contains('after clear'));
  });

  test('keeps errors and stack traces', () {
    final log = open();
    log.error(LogTag.app, 'uncaught', error: StateError('bad'), stack: StackTrace.fromString('#0 main (x.dart:1)'));
    log.flush();
    expect(log.readAll(), contains('Bad state: bad'));
    expect(log.readAll(), contains('#0 main (x.dart:1)'));
    final reopened = open();
    expect(reopened.entries.single.message, contains('#0 main (x.dart:1)'));
  });

  test('redacts registered secrets, keeping the first four characters', () {
    final log = open();
    log.addSecret('abcdef0123456789');
    log.info(LogTag.bridge, 'GET /api/abcdef0123456789/lights');
    log.flush();
    expect(log.entries.single.message, 'GET /api/abcd.../lights');
    expect(log.readAll(), isNot(contains('abcdef0123456789')));
    expect(Logger.redact('abcdef0123456789'), 'abcd...');
  });

  test('tail gives the last lines as text', () {
    final log = Logger.memory();
    for (var i = 0; i < 5; i++) {
      log.info(LogTag.ui, 'line $i');
    }
    final tail = log.tail(2).split('\n');
    expect(tail, hasLength(2));
    expect(tail.last, endsWith('line 4'));
  });

  test('export writes every file into one, replacing an earlier export', () {
    final log = open(segmentBytes: 100);
    for (var i = 0; i < 5; i++) {
      log
        ..info(LogTag.ble, 'entry $i padded out to make several files')
        ..flush();
    }
    final out = Directory('${dir.path}/exports');
    log.export(out);
    now = now.add(const Duration(minutes: 1));
    final file = log.export(out);
    expect(out.listSync(), hasLength(1));
    expect(file.readAsStringSync(), log.readAll());
  });

  test('tells listeners about new entries', () async {
    final log = Logger.memory();
    var told = 0;
    log.addListener(() => told++);
    log.info(LogTag.ui, 'a');
    log.info(LogTag.ui, 'b');
    await Future<void>.delayed(Duration.zero);
    expect(told, 1);
  });

  test('log at a given level drops debug unless debug logging is on', () {
    final log = Logger.memory();
    log.log(LogLevel.debug, LogTag.ble, 'hidden');
    log.log(LogLevel.warning, LogTag.ble, 'shown');
    log.debugEnabled = true;
    log.log(LogLevel.debug, LogTag.ble, 'now kept');
    expect(log.entries.map((e) => (e.level, e.message)), [(LogLevel.warning, 'shown'), (LogLevel.debug, 'now kept')]);
  });

  test('a persisted log in a directory that cannot be created keeps the entries in memory and says why', () {
    final blocker = File('${dir.path}/not-a-directory')..writeAsStringSync('');
    final printed = <String>[];
    final before = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    addTearDown(() => debugPrint = before);

    final log = Logger(directory: Directory(blocker.path), persist: true, clock: () => now)..info(LogTag.app, 'kept');
    expect(log.flush, returnsNormally);
    expect(printed.first, startsWith('log persist marker failed: FileSystemException'));
    expect(printed.last, startsWith('log write failed: FileSystemException'));
    expect(log.entries.single.message, 'kept');
    expect(log.totalBytes, 0);
  });

  test('a log directory that cannot be created keeps the entries in memory and says why', () {
    final blocker = File('${dir.path}/not-a-directory')..writeAsStringSync('');
    final printed = <String>[];
    final before = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    addTearDown(() => debugPrint = before);

    final log = Logger(directory: Directory(blocker.path), clock: () => now)..info(LogTag.app, 'kept');
    expect(log.flush, returnsNormally);
    expect(printed.single, startsWith('log write failed: FileSystemException'));
    expect(log.entries.single.message, 'kept');
    expect(log.totalBytes, 0, reason: 'the failed batch is not retried forever');
  });

  test('a log file that cannot be read stops the restore at the newer files', () {
    File('${dir.path}/lumen-00001.log').writeAsBytesSync([0xFF, 0xFE, 0x0A]);
    File('${dir.path}/lumen-00002.log')
        .writeAsStringSync('${LogEntry(now, LogLevel.info, LogTag.app, 'newer').format()}\n');
    final log = open();
    expect(log.entries.map((e) => e.message), ['newer']);
  });

  test('dispose writes what is still pending', () {
    final log = open()..info(LogTag.app, 'last words');
    expect(log.readAll(), isEmpty);
    log.dispose();
    expect(open().readAll(), contains('last words'));
  });
  test('dates an entry as year, month and day', () {
    expect(LogEntry.date(DateTime(2026, 3, 7, 23, 59)), '2026-03-07');
    expect(LogEntry.stamp(DateTime(2026, 3, 7, 23, 59, 1, 2)), '2026-03-07 23:59:01.002');
  });

  test('keeps only the newest entries up to its capacity', () {
    final log = Logger(capacity: 3);
    for (var i = 0; i < 5; i++) {
      log.info(LogTag.app, 'entry $i');
    }
    expect(log.entries.map((e) => e.message), ['entry 2', 'entry 3', 'entry 4']);
    expect(log.tail(2).split('\n').last, endsWith('entry 4'));
  });

  test('counts the bytes waiting and written, in UTF-8', () {
    final log = open();
    expect(log.totalBytes, 0);
    log.info(LogTag.ui, 'caf\u00e9');
    final line = '${log.entries.single.format()}\n';
    expect(log.totalBytes, line.length + 1, reason: 'the accent takes two bytes');
    log.flush();
    expect(log.totalBytes, File(log.files.single.path).lengthSync());
    log.info(LogTag.ui, 'more');
    expect(log.totalBytes, greaterThan(line.length + 1));
    log.flush();
    expect(log.totalBytes, log.files.single.lengthSync());
  });

  test('a new logger counts the files an earlier run left', () {
    open()
      ..info(LogTag.app, 'first run')
      ..flush();
    final size = File('${dir.path}/lumen-00001.log').lengthSync();
    expect(open().totalBytes, size);
  });

  test('a new logger fills the last segment of an earlier run, then numbers on from it', () {
    File('${dir.path}/lumen-00007.log')
        .writeAsStringSync('${LogEntry(now, LogLevel.info, LogTag.app, 'old').format()}\n');
    final log = open(segmentBytes: 80);
    log
      ..info(LogTag.app, 'appended to seven')
      ..flush()
      ..info(LogTag.app, 'starts eight')
      ..flush();
    expect(log.files.map((f) => f.uri.pathSegments.last), ['lumen-00007.log', 'lumen-00008.log']);
    expect(log.files.first.readAsStringSync(), contains('appended to seven'));
    expect(log.files.last.readAsStringSync(), contains('starts eight'));
  });

  test('after clear the files are numbered from one again', () {
    final log = open(segmentBytes: 60);
    for (var i = 0; i < 3; i++) {
      log
        ..info(LogTag.app, 'entry $i')
        ..flush();
    }
    log.clear();
    log
      ..info(LogTag.app, 'fresh')
      ..flush();
    expect(log.files.map((f) => f.uri.pathSegments.last), ['lumen-00001.log']);
    expect(log.totalBytes, log.files.single.lengthSync());
  });
  test('the revision goes up with every kept entry and every clear', () {
    final log = Logger.memory();
    final start = log.revision;
    log.debug(LogTag.ble, () => 'dropped');
    expect(log.revision, start, reason: 'a dropped debug entry changes nothing');
    log.info(LogTag.ui, 'kept');
    expect(log.revision, start + 1);
    log.clear();
    expect(log.revision, start + 2);
  });
}
