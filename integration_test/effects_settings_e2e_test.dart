import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/ui/light_detail_screen.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  e2e('start a candle effect on a Bluetooth bulb, then stop it', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));

    final candle = find.widgetWithText(ChoiceChip, 'Candle');
    await tester.scrollUntilVisible(candle, 200, scrollable: find.byType(Scrollable).first);
    await tester.tapAndSettle(candle);
    await tester.pumpUntil(() => bulb.state.effect == HueEffect.candle);
    await tester.tapAndSettle(find.widgetWithText(ChoiceChip, 'None'));
    await tester.pumpUntil(() => bulb.state.effect == HueEffect.none);
  });

  e2e('picking a colour ends a running candle, and the speed slider does not restart it', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));

    final scrollable = find.descendant(of: find.byType(LightDetailScreen), matching: find.byType(Scrollable)).first;
    final candle = find.widgetWithText(ChoiceChip, 'Candle');
    await tester.scrollUntilVisible(candle, 200, scrollable: scrollable);
    await tester.tapAndSettle(candle);
    await tester.pumpUntil(() => bulb.state.effect == HueEffect.candle);

    final colourTab = find.text('Colour');
    await tester.scrollUntilVisible(colourTab, -200, scrollable: scrollable);
    await tester.tapAndSettle(colourTab);
    final wheel = find.byKey(const ValueKey('color-wheel'));
    await tester.pumpUntilFound(wheel);
    final rect = tester.getRect(wheel);
    await tester.tapAt(Offset(rect.right - 4, rect.center.dy));
    await tester.pumpUntil(() => bulb.state.color is XyColor && bulb.state.effect == HueEffect.none);
    await tester.settle(const Duration(seconds: 3));

    final none = find.widgetWithText(ChoiceChip, 'None');
    // Scroll without dragging: the colour wheel claims drags that start on it.
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.settle(const Duration(milliseconds: 300));
    await tester.pumpUntilFound(none);
    expect(tester.widget<ChoiceChip>(none).selected, isTrue, reason: 'the effect chip shows None');
    expect(tester.widget<ChoiceChip>(candle).selected, isFalse);

    // The speed slider belongs to a running effect. Wherever it shows,
    // moving it must not start Candle again.
    final speed = find.byKey(const ValueKey('effect-speed'));
    if (tester.any(speed)) {
      await tester.drag(speed, const Offset(80, 0));
      await tester.settle(const Duration(seconds: 1));
    }
    expect(speed, findsNothing);
    expect(bulb.state.effect, HueEffect.none);
    expect(
      bulb.writes
          .where((w) => w.characteristic == HueGatt.control)
          .map((w) => HueBleCodec.decodeControl(w.value).effect)
          .last,
      isNull,
    );
  });

  e2e('sleep fade hands a 30 minute fade to the bulb', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Sleep fade'));
    await tester.tapAndSettle(find.text('30 minutes'));
    await tester.pumpUntil(() => bulb.state.on == false);
    final last = bulb.writes.last.value;
    expect(last.sublist(last.length - 4), [0x05, 0x02, 0x50, 0x46]);
  });

  e2e('pairing a bridge brings in its rooms, and outside changes show up', (tester, world) async {
    world.bridge
      ..addLight(SimulatedBridgeLight(name: 'Sofa'))
      ..addGroup('Living room', ['1']);
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.tapAndSettle(find.text('Hue Bridge'));
    await tester.pumpUntilFound(find.text('192.168.1.2'));
    world.bridge.pressLinkButton();
    await tester.tapAndSettle(find.text('192.168.1.2'));
    await tester.pumpUntilFound(find.byKey(const ValueKey('room-header-Living room')));

    world.bridge.lights['1']!.state = const LightState(on: true, brightness: 127);
    await tester.pumpUntilFound(
      find.descendant(of: tileOf('Sofa'), matching: find.text('On, 50%')),
      timeout: const Duration(seconds: 30),
    );
  });

  e2e('choose a light theme in settings, and forget a bridge', (tester, world) async {
    world.bridge.addLight(SimulatedBridgeLight(name: 'Sofa'));
    await world.launch(tester);
    world.bridge.pressLinkButton();
    await world.home.pairBridge('192.168.1.2');
    await tester.settle(const Duration(milliseconds: 300));

    await tester.tapAndSettle(find.text('Settings'));
    await tester.tapAndSettle(find.text('Light'));
    await tester.pumpUntil(() => Theme.of(tester.element(find.text('Light'))).brightness == Brightness.light);

    await tester.tapAndSettle(find.byKey(const ValueKey('forget-bridge')));
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Forget'));
    await tester.pumpUntil(() => world.home.bridges.isEmpty && world.home.lights.isEmpty);
  });
}
