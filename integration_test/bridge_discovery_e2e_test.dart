// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/ui/settings_screen.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  final status = find.byKey(const ValueKey('discovery-status'));
  final again = find.byKey(const ValueKey('discovery-again'));

  Future<void> openBridgeTab(WidgetTester tester) async {
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.tap(find.text('Hue Bridge'));
  }

  /// Pumps until the search ends, and returns each status line shown.
  Future<List<String>> watchSearch(WidgetTester tester, {bool Function(String line)? until}) async {
    final seen = <String>[];
    await tester.pumpUntil(() {
      if (tester.any(status)) {
        final line = tester.widget<Text>(status).data!;
        if (seen.isEmpty || seen.last != line) seen.add(line);
        if (until?.call(line) ?? false) return true;
      }
      return tester.any(again);
    }, timeout: const Duration(seconds: 30));
    return seen;
  }

  /// Opens Settings with the Advanced fold of Bridge discovery expanded.
  Future<void> openDiscoverySettings(WidgetTester tester) async {
    await tester.tapAndSettle(find.text('Settings'));
    final settings = find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first;
    final advanced = find.byKey(const ValueKey('discovery-advanced'));
    await tester.scrollUntilVisible(advanced, 200, scrollable: settings);
    await tester.tapAndSettle(advanced);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('discovery-sweep')), 200, scrollable: settings);
    await tester.settle(const Duration(milliseconds: 300));
  }

  e2e('the add-bridge screen finds the bridge on the network, without the cloud, and says how', (tester, world) async {
    world.bridge.addLight(SimulatedBridgeLightFactory.sofa());
    await world.launch(tester);
    await openBridgeTab(tester);
    final seen = await watchSearch(tester);
    expect(
      seen,
      containsAllInOrder([
        'Asking the network (mDNS, built-in)...',
        'Searching with SSDP...',
        'Scanning 254 addresses on 11 ports...',
        'Search finished, 1 bridge found',
      ]),
    );
    expect(find.byKey(ValueKey('found-${world.bridge.id}')), findsOneWidget);
    expect(find.text('Hallway bridge'), findsOneWidget);
    expect(find.text('Add :port for a phone acting as a bridge, such as 192.168.1.20:1818'), findsOneWidget);

    await tester.tapAndSettle(find.byKey(ValueKey('found-${world.bridge.id}')));
    await tester.pumpUntilFound(find.textContaining('link button'));
    world.bridge.pressLinkButton();
    await tester.pumpUntilFound(tileOf('Sofa'));
    expect(world.home.bridges.single.host, '192.168.1.2');
  });

  e2e('a paired bridge is checked first, and found once', (tester, world) async {
    await world.launch(tester);
    world.bridge.pressLinkButton();
    await world.home.pairBridge('192.168.1.2');
    await openBridgeTab(tester);
    final seen = await watchSearch(tester);
    expect(seen, containsAllInOrder(['Checking known bridges...', 'Search finished, 1 bridge found']));
    expect(find.byKey(ValueKey('found-${world.bridge.id}')), findsOneWidget);
  });

  e2e('Stop ends the search and keeps what it found, and Search again starts over', (tester, world) async {
    await world.launch(tester);
    await openBridgeTab(tester);
    await watchSearch(tester, until: (line) => line.startsWith('Scanning'));
    await tester.tapAndSettle(find.byKey(const ValueKey('discovery-stop')));
    expect(tester.widget<Text>(status).data, 'Search stopped, 1 bridge found');
    expect(find.byKey(ValueKey('found-${world.bridge.id}')), findsOneWidget);

    await tester.tapAndSettle(again);
    final seen = await watchSearch(tester);
    expect(seen.last, 'Search finished, 1 bridge found');
  });

  e2e('methods switched off in Settings are skipped, and stay off after a restart', (tester, world) async {
    await world.launch(tester);
    await openDiscoverySettings(tester);
    expect(find.text('All methods on'), findsOneWidget);
    expect(find.byKey(const ValueKey('mdns-implementation')), findsNothing, reason: 'no Android browser here');
    await tester.tapAndSettle(find.byKey(const ValueKey('discovery-ssdp')));
    await tester.tapAndSettle(find.byKey(const ValueKey('discovery-sweep')));
    expect(find.text('2 of 4 methods on'), findsOneWidget);

    await world.launch(tester);
    await openBridgeTab(tester);
    final seen = await watchSearch(tester);
    expect(seen.where((l) => l.contains('SSDP') || l.startsWith('Scanning')), isEmpty);
    expect(seen.last, 'Search finished, 1 bridge found');
  });

  e2e('with every method off the screen says so, keeps manual entry and links to the setting', (tester, world) async {
    await world.launch(tester);
    await openDiscoverySettings(tester);
    for (final key in ['discovery-known', 'discovery-mdns', 'discovery-ssdp', 'discovery-sweep']) {
      await tester.tapAndSettle(find.byKey(ValueKey(key)));
    }
    expect(find.text('All methods off'), findsOneWidget);
    await tester.tapAndSettle(find.text('Home'));

    await openBridgeTab(tester);
    await tester.pumpUntilFound(find.byKey(const ValueKey('discovery-off')));
    expect(find.text('Bridge discovery is off'), findsOneWidget);
    expect(find.byKey(const ValueKey('bridge-host')), findsOneWidget);
    expect(status, findsNothing);
    await tester.tapAndSettle(find.byKey(const ValueKey('discovery-settings')));
    await tester.pumpUntilFound(find.text('All methods off'));
    expect(find.text('Bridge discovery'), findsWidgets);
  });

  e2e('with an Android browser it asks Android by default, and the built-in query can be chosen', (
    tester,
    world,
  ) async {
    final windows = <Duration>[];
    world.androidMdns = (window) async {
      windows.add(window);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return [(host: '192.168.1.2', port: 80, bridgeId: world.bridge.id)];
    };
    await world.launch(tester);
    await openBridgeTab(tester);
    var seen = await watchSearch(tester);
    expect(seen, contains('Asking the network (mDNS, Android)...'));
    expect(windows, hasLength(1));
    await tester.pageBack();
    await tester.settle(const Duration(milliseconds: 600));

    await openDiscoverySettings(tester);
    await tester.tapAndSettle(find.text('Built-in'));
    expect(world.home.discoverySettings.mdns?.name, 'builtIn');
    await tester.tapAndSettle(find.text('Home'));

    await openBridgeTab(tester);
    seen = await watchSearch(tester);
    expect(seen, contains('Asking the network (mDNS, built-in)...'));
    expect(windows, hasLength(1), reason: 'Android was not asked again');
  });
}
