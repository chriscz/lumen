// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/log/logger.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');

  /// Records what reaches the platform share sheet, or fails like a phone
  /// without one when [fail] is set.
  List<Map<Object?, Object?>> mockShareSheet(WidgetTester tester, {PlatformException? fail}) {
    final shared = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(shareChannel, (call) async {
      if (fail != null) throw fail;
      shared.add(call.arguments as Map<Object?, Object?>);
      return 'dev.fluttercommunity.plus/share/success';
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(shareChannel, null));
    return shared;
  }

  Future<void> openDiagnostics(WidgetTester tester) async {
    await tester.tapAndSettle(find.text('Settings'));
    final open = find.byKey(const ValueKey('open-diagnostics'));
    await tester.scrollUntilVisible(open, 200, scrollable: find.byType(Scrollable).first);
    await tester.tapAndSettle(open);
  }

  Finder logSize(Pattern text) =>
      find.descendant(of: find.byKey(const ValueKey('summary-log-size')), matching: find.textContaining(text));

  /// Writes a log file from an earlier run, with [count] entries.
  File earlierRun(World world, int count) {
    final lines = [
      for (var i = 0; i < count; i++)
        LogEntry(DateTime(2026, 1, 2, 3, 4, 5), LogLevel.info, LogTag.app, 'earlier run $i').format(),
    ];
    return File('${world.logDir.path}/lumen-00001.log')..writeAsStringSync('${lines.join('\n')}\n');
  }

  e2e('Share sends the whole log as a file; Save a copy sends it without a message', (tester, world) async {
    final shared = mockShareSheet(tester);
    earlierRun(world, 3);
    await world.launch(tester);
    await openDiagnostics(tester);
    expect(find.textContaining('earlier run 2'), findsOneWidget, reason: 'the log of earlier runs is shown');

    await tester.tapAndSettle(find.byKey(const ValueKey('share-log')));
    expect(shared, hasLength(1));
    final share = shared.single;
    expect(share['subject'], 'Lumen log');
    expect(share['text'], 'Lumen diagnostics log');
    expect(share['mimeTypes'], ['text/plain']);
    final file = File((share['paths']! as List).single as String);
    expect(file.path, startsWith('${world.logDir.path}/exports/lumen-log-'));
    expect(file.readAsStringSync(), allOf(contains('earlier run 0'), contains('share the log')));

    await tester.tapAndSettle(find.byKey(const ValueKey('save-log')));
    expect(shared, hasLength(2));
    expect(shared.last.containsKey('text'), isFalse, reason: 'a saved copy carries no message');
    expect(shared.last['subject'], 'Lumen log');
    expect(
      File((shared.last['paths']! as List).single as String).readAsStringSync(),
      contains('save a copy of the log'),
    );
    expect(
      Directory('${world.logDir.path}/exports').listSync(),
      hasLength(1),
      reason: 'each export replaces the one before',
    );
  });

  e2e('a share sheet that fails says so and logs it', (tester, world) async {
    mockShareSheet(
      tester,
      fail: PlatformException(code: 'busy', message: 'no share sheet'),
    );
    await world.launch(tester);
    await openDiagnostics(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('share-log')));
    await tester.pumpUntilFound(find.textContaining('Could not share the log'));
    expect(find.textContaining('no share sheet'), findsWidgets);
    expect(
      world.log.entries.where((e) => e.level == LogLevel.warning && e.message.contains('sharing the log failed')),
      hasLength(1),
    );
  });

  e2e('the log size reads in kilobytes and megabytes', (tester, world) async {
    earlierRun(world, 40);
    await world.launch(tester);
    await openDiagnostics(tester);
    expect(logSize(RegExp(r'^\d+\.\d KB$')), findsOneWidget);

    // Errors only, so the long entry is counted but not laid out.
    await tester.tapAndSettle(find.byKey(const ValueKey('level-error')));
    world.log.info(LogTag.ui, 'x' * (1024 * 1024 + 300 * 1024));
    await tester.settle(const Duration(milliseconds: 300));
    expect(logSize(RegExp(r'^1\.[3-4] MB$')), findsOneWidget);
  });

  e2e('without a log directory Share and Copy all send the entries as text', (tester, world) async {
    final shared = mockShareSheet(tester);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    world.memoryLog = true;
    await world.launch(tester);
    world.log.warning(LogTag.ble, 'kept in memory');
    await openDiagnostics(tester);
    expect(logSize('0 B'), findsOneWidget, reason: 'nothing is written to disk');

    await tester.tapAndSettle(find.byKey(const ValueKey('share-log')));
    final share = shared.single;
    expect(share['subject'], 'Lumen log');
    expect(share['text'], allOf(contains('kept in memory'), contains('share the log')));
    expect(share.containsKey('paths'), isFalse);

    await tester.tapAndSettle(find.byKey(const ValueKey('copy-log')));
    expect(copied.single, contains('kept in memory'));
    expect(find.text('Log copied'), findsOneWidget);
  });

  e2e('an empty filter says there are no entries', (tester, world) async {
    await world.launch(tester);
    await openDiagnostics(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('level-error')));
    expect(find.text('No log entries'), findsOneWidget);
    world.log.error(LogTag.app, 'it broke');
    await tester.settle(const Duration(milliseconds: 300));
    expect(find.text('No log entries'), findsNothing);
    expect(find.textContaining('it broke'), findsOneWidget);
  });
}
