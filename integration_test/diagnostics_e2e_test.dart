// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/log/logger.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Future<void> openSettings(WidgetTester tester) => tester.tapAndSettle(find.text('Settings'));

  e2e('debug logging is off by default, turns on in Settings and stays on', (tester, world) async {
    await world.launch(tester);
    await openSettings(tester);
    final toggle = find.byKey(const ValueKey('debug-logging-switch'));
    await tester.scrollUntilVisible(toggle, 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tapAndSettle(toggle);
    expect(world.home.debugLogging, isTrue);
    expect(world.log.debugEnabled, isTrue);
    expect(world.log.persist, isTrue, reason: 'a debug log is kept between runs');

    await world.launch(tester);
    expect(world.log.debugEnabled, isTrue, reason: 'the choice is kept');
    expect(world.log.persist, isTrue);
  });

  e2e('Diagnostics shows the log, filters by level, copies and clears it', (tester, world) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    world.log.warning(LogTag.ble, 'something odd');
    await world.home.setDebugLogging(true);
    // Let the "Added" snack bar go.
    await tester.settle(const Duration(seconds: 5));

    await openSettings(tester);
    final open = find.byKey(const ValueKey('open-diagnostics'));
    await tester.scrollUntilVisible(open, 200, scrollable: find.byType(Scrollable).first);
    await tester.tapAndSettle(open);

    expect(find.textContaining('added b1'), findsOneWidget);
    expect(find.textContaining('something odd'), findsOneWidget);
    expect(find.byKey(const ValueKey('summary-lights')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('summary-lights')), matching: find.text('1')), findsOneWidget);
    expect(find.byKey(const ValueKey('summary-log-size')), findsOneWidget);

    await tester.tapAndSettle(find.byKey(const ValueKey('level-warning')));
    expect(find.textContaining('added b1'), findsNothing);
    expect(find.textContaining('something odd'), findsOneWidget);

    await tester.tapAndSettle(find.byKey(const ValueKey('copy-log')));
    expect(copied.single, contains('added b1'), reason: 'Copy all copies every level');

    await tester.tapAndSettle(find.byKey(const ValueKey('clear-log')));
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Clear'));
    expect(world.log.entries.where((e) => e.message.contains('added b1')), isEmpty);
    expect(world.log.readAll(), isNot(contains('added b1')));
  });

  e2e('Clear is only offered in debug mode', (tester, world) async {
    await world.launch(tester);
    await openSettings(tester);
    final open = find.byKey(const ValueKey('open-diagnostics'));
    await tester.scrollUntilVisible(open, 200, scrollable: find.byType(Scrollable).first);
    await tester.tapAndSettle(open);
    expect(find.byKey(const ValueKey('clear-log')), findsNothing);
    expect(find.byKey(const ValueKey('share-log')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-log')), findsOneWidget);
  });
}
