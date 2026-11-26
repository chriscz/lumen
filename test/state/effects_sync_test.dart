import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/home.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

void main() {
  late SimulatedBleCentral central;
  late SimulatedBridge bridge;
  late MemoryHomeStore store;
  late HomeController home;

  HomeController build() => HomeController(AppServices.simulated(central: central, bridge: bridge, store: store));

  setUp(() async {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    bridge = SimulatedBridge()
      ..addLight(SimulatedBridgeLight(name: 'Sofa'))
      ..addLight(SimulatedBridgeLight(name: 'Hall'))
      ..addGroup('Living room', ['1'])
      ..addGroup('Hallway', ['2']);
    store = MemoryHomeStore();
    home = build();
    await home.load();
  });

  Future<Light> addBulb(String id, {String model = 'LCA006'}) async {
    central.addBulb(SimulatedHueBulb(id: id, name: 'Bulb $id', model: model));
    final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == id);
    return home.addBluetoothLight(found);
  }

  group('effects', () {
    test('an effect is written with power, brightness and speed', () async {
      final light = await addBulb('a');
      await home.setEffect(light.id, HueEffect.candle, speed: 100);
      final bulb = central.bulbs['a']!;
      expect(bulb.state.effect, HueEffect.candle);
      expect(bulb.state.effectSpeed, 100);
      final decoded = HueBleCodec.decodeControl(bulb.writes.last.value);
      expect(decoded.on, isTrue);
      expect(home.light(light.id)!.state.effect, HueEffect.candle);
    });

    test('choosing no effect stops it by setting the colour again', () async {
      final light = await addBulb('a');
      await home.setEffect(light.id, HueEffect.fireplace);
      await home.setEffect(light.id, HueEffect.none);
      expect(central.bulbs['a']!.state.effect, anyOf(isNull, HueEffect.none));
      expect(central.bulbs['a']!.writes.last.value, isNot(contains(0x06)));
    });

    test('picking a colour while an effect runs shows the effect as ended', () async {
      final light = await addBulb('a');
      await home.setEffect(light.id, HueEffect.candle, speed: 100);
      await home.setColor(light.id, const XyColor(0.68, 0.31));
      expect(central.bulbs['a']!.state.effect, HueEffect.none);
      expect(home.light(light.id)!.state.effect, HueEffect.none);
    });

    test('a colour queued behind a pending effect does not resend the effect', () async {
      final light = await addBulb('a');
      final first = home.setColor(light.id, const WhiteColor(300));
      final effect = home.setEffect(light.id, HueEffect.candle, speed: 100);
      final colour = home.setColor(light.id, const XyColor(0.68, 0.31));
      await Future.wait([first, effect, colour]);
      final bulb = central.bulbs['a']!;
      expect(bulb.state.effect, HueEffect.none);
      expect(HueBleCodec.decodeControl(bulb.writes.last.value).effect, isNull);
      expect(home.light(light.id)!.state.effect, HueEffect.none);
    });

    test('effects are offered only on Bluetooth colour bulbs', () async {
      final colour = await addBulb('a');
      final white = await addBulb('w', model: 'LWA001');
      expect(home.light(colour.id)!.effects, isNotEmpty);
      expect(home.light(white.id)!.effects, isEmpty);
    });
  });

  group('sleep fade', () {
    test('fading off is one write with a long transition, done by the bulb', () async {
      final light = await addBulb('a');
      await home.setPower(light.id, true);
      await home.fadeOff([light.id], const Duration(minutes: 30));
      final decoded = central.bulbs['a']!.writes.last.value;
      // 30 minutes is 18000 units of 100 ms: 0x4650.
      expect(decoded, containsAllInOrder([0x01, 0x01, 0x00, 0x05, 0x02, 0x50, 0x46]));
    });

    test('a bridge light fades with transitiontime', () async {
      bridge.pressLinkButton();
      await home.pairBridge('192.168.1.2');
      await home.fadeOff([home.lights.first.id], const Duration(minutes: 10));
      expect(bridge.lastBody, {'on': false, 'transitiontime': 6000});
    });

    test('fades longer than the protocol allows are capped', () async {
      final light = await addBulb('a');
      await home.fadeOff([light.id], const Duration(hours: 3));
      final w = central.bulbs['a']!.writes.last.value;
      expect(w.sublist(w.length - 2), [0xFF, 0xFF]);
    });
  });

  group('bridge sync', () {
    test('pairing imports the bridge rooms', () async {
      bridge.pressLinkButton();
      await home.pairBridge('192.168.1.2');
      expect(home.rooms.map((r) => r.name), ['Living room', 'Hallway']);
      final living = home.rooms.first;
      expect(home.lightsIn(living.id).single.name, 'Sofa');
    });

    test('pairing again does not duplicate rooms', () async {
      bridge.pressLinkButton();
      await home.pairBridge('192.168.1.2');
      await home.pairBridge('192.168.1.2');
      expect(home.rooms.length, 2);
    });

    test('refresh picks up changes made outside the app', () async {
      bridge.pressLinkButton();
      await home.pairBridge('192.168.1.2');
      bridge.lights['1']!.state = const LightState(on: true, brightness: 77);
      await home.refresh();
      expect(home.lights.firstWhere((l) => l.name == 'Sofa').state.brightness, 77);
    });

    test('forgetting a bridge removes its lights', () async {
      bridge.pressLinkButton();
      final account = await home.pairBridge('192.168.1.2');
      await addBulb('a');
      await home.forgetBridge(account.id);
      expect(home.bridges, isEmpty);
      expect(home.lights.map((l) => l.transport), [Transport.ble]);
    });
  });

  test('the theme choice persists', () async {
    await home.setThemeChoice(ThemeChoice.light);
    final again = build();
    await again.load();
    expect(again.themeChoice, ThemeChoice.light);
  });
}
