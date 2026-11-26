import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  e2e('add a Bluetooth bulb and switch it on', (tester, world) async {
    final bulb = world.bulb('c4:2c:00:00:00:01', name: 'Desk lamp');
    await world.launch(tester);

    expect(find.text('No lights yet'), findsOneWidget);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text('Desk lamp'));
    await tester.tapAndSettle(find.text('Desk lamp'));

    await tester.pumpUntilFound(tileOf('Desk lamp'));
    expect(bulb.bonded, isTrue);
    await tester.tapAndSettle(powerSwitchOf('Desk lamp'));
    await tester.pumpUntil(() => bulb.state.on == true);
    expect(bulb.writes.last.value.sublist(0, 3), [0x01, 0x01, 0x01]);
  });

  e2e('a bulb that is not in pairing mode explains what to do', (tester, world) async {
    world.bulb('c4:2c:00:00:00:02', name: 'Shy bulb', pairingMode: false);
    await world.launch(tester);

    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text('Shy bulb'));
    await tester.tapAndSettle(find.text('Shy bulb'));
    await tester.pumpUntilFound(find.textContaining('not discoverable'));
  });

  e2e('adding a bulb pauses the scan, and a failed add resumes it', (tester, world) async {
    world.bulb('c4:2c:00:00:00:02', name: 'Shy bulb', pairingMode: false);
    await world.launch(tester);

    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text('Shy bulb'));
    expect(world.central.scans, 1);
    await tester.tapAndSettle(find.text('Shy bulb'));
    await tester.pumpUntilFound(find.textContaining('not discoverable'));
    expect(world.central.connectsWhileScanning, 0, reason: 'connecting while scanning fails on many phones');

    expect(find.text('Shy bulb'), findsOneWidget, reason: 'the found list is kept');
    world.bulb('c4:2c:00:00:00:03', name: 'Late bulb');
    await tester.pumpUntilFound(find.text('Late bulb'));
    expect(world.central.scans, 1);
  });

  e2e('pair a bridge with the link button and switch its light', (tester, world) async {
    world.bridge.addLight(SimulatedBridgeLightFactory.sofa());
    await world.launch(tester);

    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.tapAndSettle(find.text('Hue Bridge'));
    await tester.pumpUntilFound(find.text('192.168.1.2'));
    await tester.tapAndSettle(find.text('192.168.1.2'));
    await tester.pumpUntilFound(find.textContaining('link button'));
    world.bridge.pressLinkButton();

    await tester.pumpUntilFound(tileOf('Sofa'), timeout: const Duration(seconds: 5));
    await tester.tapAndSettle(powerSwitchOf('Sofa'));
    await tester.pumpUntil(() => world.bridge.lights['1']!.state.on == true);
  });
}
