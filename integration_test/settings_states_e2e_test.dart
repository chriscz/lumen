// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/bridge_server.dart';
import 'package:lumen/emulator/emulator_settings.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/ui/settings_screen.dart';

import 'harness.dart';

/// A server that starts when the test lets it, and then fails to bind, as
/// when another app holds the port.
class _SlowFailingServer extends EmulatorServer {
  final started = Completer<void>();
  String? _error;

  void failToBind(String why) {
    _error = why;
    started.complete();
  }

  @override
  bool get running => false;
  @override
  List<String> get addresses => const [];
  @override
  int? get port => null;
  @override
  bool get ssdp => false;
  @override
  bool get mdns => false;
  @override
  String? get ssdpError => null;
  @override
  String? get mdnsError => null;
  @override
  MdnsImplementation? get mdnsVia => null;
  @override
  String? get systemMdnsError => null;
  @override
  String? get error => _error;

  @override
  Future<void> start() async {
    await started.future;
    notifyListeners();
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> announcementChanged() async {}
}

void main() {
  initE2eBinding();

  Finder settingsScrollable() =>
      find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first;

  e2e('removed bridge lights are listed under the bridge and can be added back', (tester, world) async {
    world.bridge
      ..addLight(SimulatedBridgeLight(name: 'Sofa'))
      ..addLight(SimulatedBridgeLight(name: 'Lamp'))
      ..addLight(SimulatedBridgeLight(name: 'Hall'));
    await world.launch(tester);
    world.bridge.pressLinkButton();
    await world.home.pairBridge('192.168.1.2', interval: Duration.zero);
    String id(String lightId) => '${world.bridge.id}/$lightId';
    final lamp = world.home.lights.firstWhere((l) => l.address == id('2')).id;
    final hall = world.home.lights.firstWhere((l) => l.address == id('3')).id;
    await world.home.remove(lamp);
    await world.home.remove(hall);
    await tester.tapAndSettle(find.text('Settings'));

    final removed = find.byKey(ValueKey('bridge-removed-${world.bridge.id}'));
    expect(find.text('2 removed lights'), findsOneWidget);
    await tester.tapAndSettle(removed);
    expect(find.text('Lamp'), findsOneWidget);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-back-2')));
    expect(world.home.lights.map((l) => l.name), contains('Lamp'));
    expect(find.text('1 removed light'), findsOneWidget);

    await tester.tapAndSettle(removed);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-all-back')));
    expect(world.home.lights.map((l) => l.name), containsAll(['Sofa', 'Lamp', 'Hall']));
    expect(removed, findsNothing);
  });

  e2e('the demo build says its lights are simulated', (tester, world) async {
    world.demo = true;
    await world.launch(tester);
    await tester.tapAndSettle(find.text('Settings'));
    expect(find.text('Demo mode'), findsOneWidget);
    expect(find.textContaining('Build without DEMO'), findsOneWidget);
  });

  e2e('the real build has no demo card', (tester, world) async {
    await world.launch(tester);
    await tester.tapAndSettle(find.text('Settings'));
    expect(find.text('Demo mode'), findsNothing);
  });

  e2e('the emulated bridge shows Starting, then why it is not running', (tester, world) async {
    final server = _SlowFailingServer();
    world.emulatorServer = (_, _, _) => server;
    await world.launch(tester);
    await tester.tapAndSettle(find.text('Settings'));
    final toggle = find.byKey(const ValueKey('bridge-emulator-switch'));
    await tester.scrollUntilVisible(toggle, 200, scrollable: settingsScrollable());
    await tester.tapAndSettle(toggle);

    final starting = find.byKey(const ValueKey('emulator-starting'));
    await tester.scrollUntilVisible(starting, 200, scrollable: settingsScrollable());
    expect(find.descendant(of: starting, matching: find.text('Starting')), findsOneWidget);
    expect(find.byKey(const ValueKey('emulator-address')), findsNothing);

    server.failToBind('port 1818 is busy');
    await tester.settle(const Duration(milliseconds: 300));
    final error = find.byKey(const ValueKey('emulator-error'));
    await tester.scrollUntilVisible(error, 200, scrollable: settingsScrollable());
    expect(find.descendant(of: error, matching: find.text('Not running')), findsOneWidget);
    expect(find.descendant(of: error, matching: find.text('port 1818 is busy')), findsOneWidget);
    expect(starting, findsNothing);
  });
}
