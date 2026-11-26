// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/app.dart';
import 'package:lumen/domain/home.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/emulator/bridge_emulator.dart';
import 'package:lumen/emulator/emulator_settings.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/emulator_store.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';

void main() {
  late SimulatedBleCentral central;
  late SimulatedHueBulb bulb;
  late MemoryHomeStore store;
  late MemoryEmulatorStore emulatorStore;
  late HomeController home;

  const lightId = 'ble:aa';

  // Built inside each test, in its fake-time zone: the driver chains
  // futures, and ones made in the root zone would never resume under
  // pump.
  void world() {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    bulb = central.addBulb(SimulatedHueBulb(id: 'aa', name: 'Desk', bonded: true));
    store = MemoryHomeStore();
    // A light saved on an earlier run, last seen off and out of reach.
    store.json = jsonEncode(
      const HomeSnapshot(
        lights: [
          Light(
            id: lightId,
            name: 'Desk',
            transport: Transport.ble,
            address: 'aa',
            kind: LightKind.color,
            state: LightState(on: false, brightness: 254),
            reachable: false,
          ),
        ],
      ).toJson(),
    );
    emulatorStore = MemoryEmulatorStore();
    home = HomeController(
      AppServices.simulated(central: central, bridge: SimulatedBridge(), store: store, emulatorStore: emulatorStore),
    );
  }

  Future<void> launch(WidgetTester tester, HueApp app) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    for (var i = 0; i < 50 && !(home.loaded && (_emulatorOf(tester)?.loaded ?? false)); i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  }

  ThemeMode themeMode(WidgetTester tester) => tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

  testWidgets('loads a home that is not loaded yet, probes its lights and starts its own emulator', (tester) async {
    world();
    final settings = EmulatorSettings.create()..enabled = true;
    emulatorStore.json = jsonEncode(settings.toJson());
    bulb.changeLocally(const LightCommand(on: true));

    await launch(tester, HueApp(home: home));
    expect(home.loaded, isTrue);
    expect(home.light(lightId)!.reachable, isTrue, reason: 'the launch probe reached the bulb');
    expect(home.light(lightId)!.isOn, isTrue);
    expect(find.text('Desk'), findsWidgets);

    final own = _emulatorOf(tester)!;
    expect(own.loaded, isTrue);
    expect(own.running, isTrue, reason: 'the emulator was left on, so it starts at launch');

    await unmount(tester);
    expect(own.running, isFalse, reason: 'the app disposes the emulator it made');
  });

  testWidgets('a home loaded already is neither loaded nor probed again; the given emulator is kept', (tester) async {
    world();
    await home.load();
    final emulator = BridgeEmulator(home);
    addTearDown(emulator.dispose);

    await launch(tester, HueApp(home: home, emulator: emulator));
    expect(_emulatorOf(tester), same(emulator));
    expect(emulator.loaded, isTrue, reason: 'the emulator still loads');
    expect(central.readRequests, isEmpty, reason: 'whoever loaded the home connects it');
    expect(home.light(lightId)!.reachable, isFalse);

    await unmount(tester);
    expect(() => emulator.addListener(() {}), returnsNormally, reason: 'not disposed by the app');
  });

  testWidgets('follows the theme choice', (tester) async {
    world();
    await home.load();
    await launch(tester, HueApp(home: home));
    expect(themeMode(tester), ThemeMode.dark, reason: 'dark by default');

    await home.setThemeChoice(ThemeChoice.light);
    await tester.pump();
    expect(themeMode(tester), ThemeMode.light);

    await home.setThemeChoice(ThemeChoice.system);
    await tester.pump();
    expect(themeMode(tester), ThemeMode.system);
    await unmount(tester);
  });

  testWidgets('builds the app again only for a new theme choice, with the same themes', (tester) async {
    world();
    await home.load();
    await launch(tester, HueApp(home: home));
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    final first = app();

    await home.setDebugLogging(true);
    await tester.pump();
    expect(app(), same(first), reason: 'another change to the home leaves the app as it is');

    await home.setThemeChoice(ThemeChoice.light);
    await tester.pump();
    expect(app(), isNot(same(first)));
    expect(app().theme, same(first.theme), reason: 'the themes are built once');
    expect(app().darkTheme, same(first.darkTheme));
    await unmount(tester);
  });
}

BridgeEmulator? _emulatorOf(WidgetTester tester) {
  final scopes = find.byWidgetPredicate((w) => w.runtimeType.toString() == 'EmulatorScope');
  if (scopes.evaluate().isEmpty) return null;
  return (tester.widget(scopes) as InheritedNotifier<BridgeEmulator>).notifier;
}
