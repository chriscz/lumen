import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';

void main() {
  late SimulatedBleCentral central;
  late SimulatedBridge bridge;
  late MemoryHomeStore store;
  late HomeController home;

  HomeController build() => HomeController(AppServices.simulated(central: central, bridge: bridge, store: store));

  setUp(() async {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    bridge = SimulatedBridge()..addLight(SimulatedBridgeLight(name: 'Sofa'));
    store = MemoryHomeStore();
    home = build();
    await home.load();
  });

  Future<Light> addBulb(String id, {String name = 'Desk'}) async {
    central.addBulb(SimulatedHueBulb(id: id, name: name));
    final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == id);
    return home.addBluetoothLight(found);
  }

  test('scan hides bulbs that were already added', () async {
    await addBulb('aa');
    central.addBulb(SimulatedHueBulb(id: 'bb'));
    final next = await home.scanBluetooth().first;
    expect(next.deviceId, 'bb');
  });

  test('diagnostics read the Bluetooth status and count the connected bulbs', () async {
    expect(await home.bluetoothStatus(), containsPair('Bluetooth', 'poweredOn'));
    expect(home.connectedBulbCount, 0);
    await addBulb('aa');
    await addBulb('bb', name: 'Lamp');
    expect(home.connectedBulbCount, 2);
    central.dropConnection('aa');
    await Future<void>.delayed(Duration.zero);
    expect(home.connectedBulbCount, 1);
  });

  test('adds a Bluetooth light with its name and state', () async {
    final light = await addBulb('aa');
    expect(home.lights.single.id, light.id);
    expect(light.name, 'Desk');
    expect(light.transport, Transport.ble);
    expect(light.reachable, isTrue);
  });

  test('setPower switches a Bluetooth bulb and updates the model at once', () async {
    final light = await addBulb('aa');
    final done = home.setPower(light.id, true);
    expect(home.light(light.id)!.isOn, isTrue, reason: 'optimistic');
    await done;
    expect(central.bulbs['aa']!.state.on, isTrue);
  });

  test('a failed write rolls back, marks the light unreachable and reports an error', () async {
    final light = await addBulb('aa');
    central.dropConnection('aa');
    central.bulbs['aa']!.inRange = false;
    final errors = <LightError>[];
    home.errors.listen(errors.add);
    await home.setPower(light.id, true);
    expect(home.light(light.id)!.isOn, isFalse);
    expect(home.light(light.id)!.reachable, isFalse);
    expect(errors.single, isA<LightUnreachable>());
  });

  test('rapid changes are coalesced so the last value always lands', () async {
    central = SimulatedBleCentral(scanDelay: Duration.zero, latency: const Duration(milliseconds: 20));
    home = build();
    await home.load();
    final light = await addBulb('aa');
    final bulb = central.bulbs['aa']!;
    final before = bulb.writes.length;
    final futures = [for (var b = 10; b <= 200; b += 10) home.setBrightness(light.id, b)];
    await Future.wait(futures);
    expect(bulb.state.brightness, 200);
    expect(bulb.writes.length - before, lessThan(5));
  });

  test('pairs a bridge and imports its lights', () async {
    Future<void>.delayed(const Duration(milliseconds: 50), bridge.pressLinkButton);
    final account = await home.pairBridge('192.168.1.2', interval: const Duration(milliseconds: 20));
    expect(account.host, '192.168.1.2');
    expect(home.lights.single.name, 'Sofa');
    expect(home.lights.single.transport, Transport.bridge);
  });

  test('setPower on a bridge light sends it through the bridge', () async {
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2');
    await home.setPower(home.lights.single.id, true);
    expect(bridge.lights['1']!.state.on, isTrue);
  });

  test('lights, bridges and names survive a restart', () async {
    final light = await addBulb('aa');
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2');
    await home.rename(light.id, 'Reading lamp');
    final again = build();
    await again.load();
    expect(again.lights.map((l) => l.name), ['Reading lamp', 'Sofa']);
    expect(again.bridges.single.host, '192.168.1.2');
  });

  test('remove forgets a light', () async {
    final light = await addBulb('aa');
    await home.remove(light.id);
    expect(home.lights, isEmpty);
  });

  test('a report from the bulb updates the model', () async {
    final light = await addBulb('aa');
    central.bulbs['aa']!.changeLocally(const LightCommand(on: true, brightness: 33));
    await pumpEventQueue();
    expect(home.light(light.id)!.state.brightness, 33);
  });
  group('increment 1: my lights', () {
    test('after a restart, connectAll marks bulbs in range reachable and out of range unreachable', () async {
      final near = await addBulb('aa', name: 'Near');
      await addBulb('bb', name: 'Far');
      central.bulbs['aa']!.changeLocally(const LightCommand(on: true, brightness: 50));
      central.bulbs['bb']!.inRange = false;
      central.dropConnection('aa');
      central.dropConnection('bb');
      final again = build();
      await again.load();
      expect(again.light(near.id)!.reachable, isFalse, reason: 'unknown until probed');
      await again.connectAll();
      expect(again.light(near.id)!.reachable, isTrue);
      expect(again.light(near.id)!.state.brightness, 50);
      expect(again.light(HomeController.bleId('bb'))!.reachable, isFalse);
    });

    // Identify sends the blink command to 0006 (docs/protocol.md);
    // the power blink is the fallback, covered in test/ble/identify_test.dart.
    test('identify blinks a bulb and leaves it as it was', () async {
      final light = await addBulb('aa');
      final bulb = central.bulbs['aa']!;
      final before = bulb.writes.length;
      await home.identify(light.id, step: Duration.zero);
      expect(bulb.writes.length - before, 1);
      expect(bulb.identifies, 1);
      expect(bulb.state.on, isFalse);
    });

    test('identify on a bridge light sends an alert', () async {
      bridge.pressLinkButton();
      await home.pairBridge('192.168.1.2');
      await home.identify(home.lights.single.id);
      expect(bridge.alerts, ['1']);
    });

    test('favourites persist', () async {
      final light = await addBulb('aa');
      await home.toggleFavorite(light.id);
      final again = build();
      await again.load();
      expect(again.light(light.id)!.favorite, isTrue);
    });

    test('restore puts a removed light back', () async {
      final light = await addBulb('aa');
      final removed = home.light(light.id)!;
      await home.remove(light.id);
      await home.restore(removed);
      expect(home.lights.single.name, 'Desk');
    });
  });

  test('keeps a colour temperature inside what a Bluetooth bulb can show', () async {
    final light = await addBulb('aa');
    await home.setColor(light.id, const WhiteColor(90));
    expect(central.bulbs['aa']!.state.color, const WhiteColor(HueRange.minMireds));
  });
}
