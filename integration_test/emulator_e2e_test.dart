// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/ui/settings_screen.dart';

import 'harness.dart';

Future<void> scrollToEnd(WidgetTester tester) async {
  final settings = find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(find.text('Lumen 1.0'), 300, scrollable: settings);
  await tester.settle(const Duration(milliseconds: 300));
}

void main() {
  initE2eBinding();

  // The server is in process here: real sockets under fake time are
  // unreliable, so the test talks to the emulator's API handler directly.
  // test/emulator/bridge_server_test.dart covers the sockets.
  Object? api(World world, String method, String path, [Object? body]) =>
      world.emulator.api.handle(method, path, body == null ? '' : jsonEncode(body)).$2;

  /// Opens Settings and scrolls to its end, so the whole bridge section sits
  /// clear of the navigation bar.
  Future<void> openEmulatorSettings(WidgetTester tester) async {
    await tester.tapAndSettle(find.text('Settings'));
    await scrollToEnd(tester);
    await tester.pumpUntilFound(find.byKey(const ValueKey('bridge-emulator-switch')));
  }

  e2e('act as a Hue Bridge: switch it on, press the link button and let another app pair', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await openEmulatorSettings(tester);

    expect(find.text('http://192.168.1.50:1818'), findsNothing);
    await tester.tapAndSettle(find.byKey(const ValueKey('bridge-emulator-switch')));
    await tester.pumpUntil(() => world.emulator.running);
    await tester.pumpUntilFound(find.text('http://192.168.1.50:1818'));
    expect(find.textContaining('port 80'), findsOneWidget);
    expect(find.textContaining('SSDP'), findsOneWidget);

    final refused = api(world, 'POST', '/api', {'devicetype': 'e2e#client'}) as List;
    expect((refused.single as Map)['error']['type'], 101);

    await scrollToEnd(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('emulator-link-button')));
    expect(find.textContaining(RegExp(r'\d+ s left')), findsOneWidget);

    final paired = api(world, 'POST', '/api', {'devicetype': 'e2e#client'}) as List;
    final key = (paired.single as Map)['success']['username'] as String;
    await tester.pumpUntilFound(find.text('e2e#client'));

    final lights = api(world, 'GET', '/api/$key/lights') as Map;
    expect(lights['1']['name'], 'Desk lamp');
    api(world, 'PUT', '/api/$key/lights/1/state', {'on': true, 'bri': 200});
    await tester.pumpUntil(() => bulb.state.on == true && bulb.state.brightness == 200);
    await tester.tapAndSettle(find.text('Home'));
    await tester.pumpUntilFound(find.descendant(of: tileOf('Desk lamp'), matching: find.text('On, 79%')));

    await openEmulatorSettings(tester);
    await tester.tapAndSettle(find.byKey(ValueKey('revoke-$key')));
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpUntilGone(find.text('e2e#client'));
    final denied = api(world, 'GET', '/api/$key/lights') as List;
    expect((denied.single as Map)['error']['type'], 1);
  });

  e2e('the bridge stays on, with its paired apps, after the app restarts', (tester, world) async {
    world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await openEmulatorSettings(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('bridge-emulator-switch')));
    await tester.pumpUntil(() => world.emulator.running);
    world.emulator.pressLinkButton();
    final paired = api(world, 'POST', '/api', {'devicetype': 'home-assistant#phone'}) as List;
    final key = (paired.single as Map)['success']['username'] as String;
    await tester.settle(const Duration(milliseconds: 300));

    await world.launch(tester);
    await tester.pumpUntil(() => world.emulator.running);
    final lights = api(world, 'GET', '/api/$key/lights') as Map;
    expect(lights.keys, ['1']);
    await openEmulatorSettings(tester);
    await tester.pumpUntilFound(find.text('home-assistant#phone'));
  });

  e2e('announce on Wi-Fi: switching it off stops discovery but keeps the address', (tester, world) async {
    await world.launch(tester);
    await openEmulatorSettings(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('bridge-emulator-switch')));
    await tester.pumpUntil(() => world.emulator.running);
    await scrollToEnd(tester);
    final announce = find.byKey(const ValueKey('emulator-announce-switch'));
    await tester.pumpUntilFound(announce);
    expect(tester.widget<SwitchListTile>(announce).value, isTrue);
    expect(
      find.textContaining(RegExp(r'^Announcing as Lumen-[0-9A-F]{6} on Wi-Fi via mDNS and SSDP$')),
      findsOneWidget,
    );

    await tester.tapAndSettle(announce);
    await tester.pumpUntil(() => !world.emulator.announcing);
    await tester.pumpUntilFound(find.textContaining('Not announcing'));
    expect(tester.widget<SwitchListTile>(announce).value, isFalse);
    expect(find.text('http://192.168.1.50:1818'), findsOneWidget);
    expect(world.emulator.running, isTrue);
    expect((jsonDecode(world.emulatorStore.json!) as Map)['announce'], isFalse);

    await tester.tapAndSettle(announce);
    await tester.pumpUntilFound(find.textContaining('via mDNS and SSDP'));
    expect(world.emulator.announcing, isTrue);
  });
}
