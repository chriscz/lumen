// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/sim/simulated_bridge_platform.dart';
import 'package:lumen/ui/settings_screen.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Finder settingsScrollable() =>
      find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first;

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: settingsScrollable());
    await tester.settle(const Duration(milliseconds: 300));
  }

  /// Opens Settings and switches the bridge on.
  Future<void> startBridge(WidgetTester tester, World world) async {
    await tester.tapAndSettle(find.text('Settings'));
    final toggle = find.byKey(const ValueKey('bridge-emulator-switch'));
    await scrollTo(tester, toggle);
    await tester.tapAndSettle(toggle);
    await tester.pumpUntil(() => world.emulator.running);
  }

  String pair(World world, String devicetype) {
    world.emulator.pressLinkButton();
    final (_, json) = world.emulator.api.handle('POST', '/api', jsonEncode({'devicetype': devicetype}));
    return (((json as List).single as Map)['success'] as Map)['username'] as String;
  }

  Map<String, Object?> saved(World world) => jsonDecode(world.emulatorStore.json!) as Map<String, Object?>;

  e2e('run in the background: the service runs with the bridge and its switch stops it', (tester, world) async {
    await world.launch(tester);
    await startBridge(tester, world);
    await tester.pumpUntil(() => world.background.running);
    expect(world.background.text, 'Listening on 192.168.1.50:1818, no apps active');
    expect(world.background.calls, contains('requestNotifications'));
    await tester.pumpUntilFound(find.text('http://192.168.1.50:1818'));

    final background = find.byKey(const ValueKey('emulator-background-switch'));
    await scrollTo(tester, background);
    expect(tester.widget<SwitchListTile>(background).value, isTrue);
    await tester.tapAndSettle(background);
    await tester.pumpUntil(() => !world.background.running);
    expect(tester.widget<SwitchListTile>(background).value, isFalse);
    expect(saved(world)['background'], isFalse);
    expect(world.emulator.running, isTrue, reason: 'the bridge itself keeps running');

    final battery = find.byKey(const ValueKey('emulator-battery'));
    await scrollTo(tester, battery);
    expect(find.textContaining('Unrestricted'), findsOneWidget);
    await tester.tapAndSettle(battery);
    expect(world.background.calls.last, 'openBatterySettings');

    await scrollTo(tester, find.byKey(const ValueKey('bridge-emulator-switch')));
    await tester.tapAndSettle(find.byKey(const ValueKey('bridge-emulator-switch')));
    await tester.pumpUntil(() => !world.emulator.running);
    expect(world.background.running, isFalse);
  });

  e2e('connected apps: a summary, when each was last seen, and removal after a confirm', (tester, world) async {
    await world.launch(tester);
    await startBridge(tester, world);
    final key = pair(world, 'home-assistant#phone');
    final summary = find.byKey(const ValueKey('emulator-apps-summary'));
    await tester.pumpUntilFound(summary);
    await scrollTo(tester, summary);
    expect(find.text('1 app paired, 1 active in the last 5 minutes'), findsOneWidget);
    final tile = find.byKey(ValueKey('paired-$key'));
    expect(find.descendant(of: tile, matching: find.textContaining('Active now')), findsOneWidget);
    await tester.pumpUntil(() => world.background.text == 'Listening on 192.168.1.50:1818, 1 app active');

    final app = world.emulator.settings.users[key]!;
    world.emulator.settings.users[key] = app.used(DateTime.now().toUtc().subtract(const Duration(hours: 3)));
    world.emulator.tick();
    await tester.pumpUntilFound(find.descendant(of: tile, matching: find.textContaining('Last seen 3 h ago')));
    expect(find.text('1 app paired, none active in the last 5 minutes'), findsOneWidget);

    final remove = find.byKey(ValueKey('revoke-$key'));
    await tester.tapAndSettle(remove);
    expect(find.text('Remove home-assistant#phone?'), findsOneWidget);
    await tester.tapAndSettle(find.text('Cancel'));
    expect(tile, findsOneWidget);
    await tester.tapAndSettle(remove);
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpUntilGone(tile);
    expect(world.emulator.pairedApps, isEmpty);
    final (_, denied) = world.emulator.api.handle('GET', '/api/$key/lights', '');
    expect((((denied as List).single as Map)['error'] as Map)['type'], 1);
  });

  e2e('advanced: mDNS, SSDP and staying awake sit in a fold, closed at first', (tester, world) async {
    await world.launch(tester);
    await startBridge(tester, world);
    final advanced = find.byKey(const ValueKey('bridge-advanced'));
    await scrollTo(tester, advanced);
    expect(find.byKey(const ValueKey('emulator-mdns-switch')), findsNothing);
    expect(find.byKey(const ValueKey('emulator-mdns-implementation')), findsNothing);
    await tester.tapAndSettle(advanced);

    final mdns = find.byKey(const ValueKey('emulator-mdns-switch'));
    final ssdp = find.byKey(const ValueKey('emulator-ssdp-switch'));
    final awake = find.byKey(const ValueKey('emulator-stay-awake-switch'));
    await scrollTo(tester, awake);
    expect(find.byKey(const ValueKey('emulator-mdns-implementation')), findsNothing, reason: 'only built-in here');

    await tester.tapAndSettle(mdns);
    await tester.pumpUntil(() => !world.emulator.mdns);
    expect(find.textContaining(RegExp(r'on Wi-Fi via SSDP$')), findsOneWidget);
    await tester.tapAndSettle(ssdp);
    await tester.pumpUntilFound(find.textContaining('mDNS and SSDP are off'));
    expect([saved(world)['mdnsEnabled'], saved(world)['ssdpEnabled']], [false, false]);
    expect(world.emulator.running, isTrue);

    await tester.tapAndSettle(awake);
    await tester.pumpUntil(() => world.background.stayAwakeWhileCharging);
    expect(saved(world)['stayAwakeWhileCharging'], isTrue);
  });

  e2e('with Android mDNS the implementation can be swapped while the bridge runs', (tester, world) async {
    final nsd = world.nsd = SimulatedSystemMdns();
    await world.launch(tester);
    await startBridge(tester, world);
    await tester.pumpUntilFound(find.textContaining('via mDNS (Android) and SSDP'));
    expect(nsd.available, isTrue);
    final advanced = find.byKey(const ValueKey('bridge-advanced'));
    await scrollTo(tester, advanced);
    await tester.tapAndSettle(advanced);
    final choice = find.byKey(const ValueKey('emulator-mdns-implementation'));
    await scrollTo(tester, choice);
    expect(find.text('Android (system)'), findsOneWidget);
    await tester.tapAndSettle(find.text('Built-in'));
    await tester.pumpUntilFound(find.textContaining(RegExp(r'via mDNS and SSDP$')));
    expect(saved(world)['mdnsImplementation'], 'builtIn');
  });

  e2e('the help screen explains discovery, sleep, trade-offs and privacy', (tester, world) async {
    await world.launch(tester);
    await tester.tapAndSettle(find.text('Settings'));
    final help = find.byKey(const ValueKey('emulator-help'));
    await scrollTo(tester, help);
    await tester.tapAndSettle(help);
    await tester.pumpUntilFound(find.byKey(const ValueKey('bridge-help')));
    expect(find.text('Running Lumen as a bridge'), findsOneWidget);
    expect(find.textContaining('1818 to 2727'), findsOneWidget);
    expect(find.textContaining('With announcing off, other devices can still reach'), findsOneWidget);
    for (final heading in [
      'How other devices find it',
      'Why Android puts apps to sleep',
      'What the settings do',
      'Trade-offs',
      'Privacy',
    ]) {
      await tester.scrollUntilVisible(find.text(heading), 200, scrollable: find.byType(Scrollable).last);
      expect(find.text(heading), findsOneWidget);
    }
    expect(find.textContaining('Everything stays on your local network'), findsOneWidget);
    await tester.pageBack();
    await tester.settle(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('bridge-help')), findsNothing);
  });
}
