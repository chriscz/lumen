import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/ui/widgets/light_controls.dart';
import 'package:lumen/ui/widgets/light_tile.dart';

/// Pumps [build] inside a page, and returns a function that rebuilds it, as
/// a report or poll from the light would.
Future<void Function()> _pump(WidgetTester tester, Widget Function() build) async {
  late StateSetter rebuild;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return build();
            },
          ),
        ),
      ),
    ),
  );
  return () => rebuild(() {});
}

double _sliderValue(WidgetTester tester, Key key) => tester.widget<Slider>(find.byKey(key)).value;

void main() {
  testWidgets('the tile brightness thumb stays under the finger when a report arrives mid drag', (tester) async {
    var brightness = 50;
    final sent = <int>[];
    final report = await _pump(
      tester,
      () => SizedBox(
        width: 220,
        height: 200,
        child: LightTile(
          light: Light(
            id: 'ble:b1',
            name: 'Desk lamp',
            transport: Transport.ble,
            address: 'b1',
            reachable: true,
            state: LightState(on: true, brightness: brightness),
          ),
          onPower: (_) {},
          onBrightness: sent.add,
        ),
      ),
    );
    const key = ValueKey('tile-brightness');
    final slider = tester.getRect(find.byKey(key));
    final gesture = await tester.startGesture(slider.center);
    await gesture.moveTo(Offset(slider.left + slider.width * 0.9, slider.center.dy));
    await tester.pump();
    final dragged = _sliderValue(tester, key);
    expect(dragged, greaterThan(150));
    expect(sent, isNotEmpty);

    brightness = 20;
    report();
    await tester.pump();
    expect(_sliderValue(tester, key), dragged);

    await gesture.up();
    await tester.pump();
    expect(sent.last, dragged.round());
    expect(_sliderValue(tester, key), 20, reason: 'after the drag the tile shows the light again');
  });

  testWidgets('the effect speed thumb follows the finger and sends when let go', (tester) async {
    final sent = <int>[];
    final report = await _pump(
      tester,
      () => SizedBox(
        width: 380,
        child: EffectsCard(effect: HueEffect.candle, speed: 128, onEffect: (_) {}, onSpeed: sent.add),
      ),
    );
    const key = ValueKey('effect-speed');
    final slider = tester.getRect(find.byKey(key));
    final gesture = await tester.startGesture(slider.center);
    await gesture.moveTo(Offset(slider.left + slider.width * 0.9, slider.center.dy));
    await tester.pump();
    final dragged = _sliderValue(tester, key);
    expect(dragged, greaterThan(200));
    expect(sent, isEmpty, reason: 'speed is sent once, at the end of the drag');

    report();
    await tester.pump();
    expect(_sliderValue(tester, key), dragged);

    await gesture.up();
    await tester.pump();
    expect(sent, [dragged.round()]);
  });
}
