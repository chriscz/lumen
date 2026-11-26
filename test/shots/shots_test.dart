import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/home.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_bridge.dart';

import '../../integration_test/harness.dart';

// Renders the README screenshots with real fonts. Opt in with:
//   SHOTS=1 flutter test test/shots --update-goldens
// then copy test/shots/out/*.png to docs/screenshots/.
final enabled = Platform.environment.containsKey('SHOTS');

Future<void> loadFonts() async {
  if (!enabled) return;
  final dir = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    roboto.addFont(Future.value(ByteData.sublistView(File('$dir/$f').readAsBytesSync())));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(File('$dir/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
}

Future<void> setup(WidgetTester tester, World world) async {
  world.bulb('b1', name: 'Desk lamp');
  world.bulb('b2', name: 'Bedside', model: 'LTA001');
  world.bulb('b3', name: 'Hallway', model: 'LWA001');
  world.bridge
    ..addLight(SimulatedBridgeLight(name: 'Sofa'))
    ..addLight(SimulatedBridgeLight(name: 'Lightstrip'))
    ..addLight(SimulatedBridgeLight(name: 'Kitchen', type: 'Color temperature light'))
    ..addGroup('Living room', ['1', '2'])
    ..addGroup('Kitchen', ['3']);
  await world.launch(tester);
  for (final n in ['Desk lamp', 'Bedside', 'Hallway']) {
    await world.addBulbThroughUi(tester, n);
  }
  world.bridge.pressLinkButton();
  await world.home.pairBridge('192.168.1.2');
  final h = world.home;
  final study = await h.createRoom('Study', ['ble:b1', 'ble:b2']);
  await h.send('ble:b1', const LightCommand(on: true, brightness: 230, color: XyColor(0.5614, 0.4156)));
  await h.send('ble:b2', const LightCommand(on: true, brightness: 120, color: WhiteColor(400)));
  final sofa = h.lights.firstWhere((l) => l.name == 'Sofa').id;
  final strip = h.lights.firstWhere((l) => l.name == 'Lightstrip').id;
  final kitchen = h.lights.firstWhere((l) => l.name == 'Kitchen').id;
  await h.send(sofa, const LightCommand(on: true, brightness: 200, color: XyColor(0.4149, 0.1776)));
  await h.send(strip, const LightCommand(on: true, brightness: 160, color: XyColor(0.17, 0.12)));
  await h.send(kitchen, const LightCommand(on: false));
  await h.saveScene('Movie night', [sofa, strip, 'ble:b1']);
  expect(study.name, 'Study');
  await tester.settle(const Duration(seconds: 5));
}

Future<void> shot(WidgetTester tester, String name) async {
  await tester.settle(const Duration(milliseconds: 800));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name.png'));
}

void main() {
  setUpAll(loadFonts);

  if (!enabled) return;
  e2e('screens', (tester, world) async {
    await setup(tester, world);
    await shot(tester, '1-home');
    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.text('Colour'));
    await shot(tester, '2-colour-wheel');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await shot(tester, '3-effects');
    await tester.pageBack();
    await tester.settle(const Duration(milliseconds: 600));
    await tester.tapAndSettle(find.text('Profiles'));
    await shot(tester, '4-profiles');
    await tester.tapAndSettle(find.text('Home'));
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await shot(tester, '5-add-light');
    await tester.pageBack();
    await tester.settle(const Duration(milliseconds: 600));
    await world.home.setThemeChoice(ThemeChoice.light);
    await shot(tester, '6-home-light');
  });
}
