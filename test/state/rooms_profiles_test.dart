import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/home.dart';
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

  Future<void> start({int maxConnections = 7}) async {
    central = SimulatedBleCentral(scanDelay: Duration.zero, maxConnections: maxConnections);
    bridge = SimulatedBridge()..addLight(SimulatedBridgeLight(name: 'Sofa'));
    store = MemoryHomeStore();
    home = build();
    await home.load();
  }

  Future<Light> addBulb(String id, {String model = 'LCA006'}) async {
    central.addBulb(SimulatedHueBulb(id: id, name: 'Bulb $id', model: model));
    final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == id);
    return home.addBluetoothLight(found);
  }

  group('rooms', () {
    setUp(start);

    test('a room groups lights, and a light belongs to at most one room', () async {
      final a = await addBulb('a');
      final b = await addBulb('b');
      final living = await home.createRoom('Living room', [a.id, b.id]);
      final study = await home.createRoom('Study', [b.id]);
      expect(home.lightsIn(living.id).map((l) => l.id), [a.id]);
      expect(home.lightsIn(study.id).map((l) => l.id), [b.id]);
    });

    test('room power reaches Bluetooth and bridge lights alike', () async {
      final a = await addBulb('a');
      bridge.pressLinkButton();
      await home.pairBridge('192.168.1.2');
      final sofa = home.lights.firstWhere((l) => l.transport == Transport.bridge);
      final room = await home.createRoom('Living room', [a.id, sofa.id]);
      await home.setRoomPower(room.id, true);
      expect(central.bulbs['a']!.state.on, isTrue);
      expect(bridge.lights['1']!.state.on, isTrue);
      expect(home.roomIsOn(room.id), isTrue);
    });

    test('deleting a room keeps its lights, unassigned', () async {
      final a = await addBulb('a');
      final room = await home.createRoom('Living room', [a.id]);
      await home.deleteRoom(room.id);
      expect(home.rooms, isEmpty);
      expect(home.light(a.id)!.roomId, isNull);
    });

    test('rooms survive a restart', () async {
      final a = await addBulb('a');
      await home.createRoom('Living room', [a.id]);
      final again = build();
      await again.load();
      expect(again.rooms.single.name, 'Living room');
      expect(again.lightsIn(again.rooms.single.id).single.id, a.id);
    });
  });

  group('connection budget', () {
    test('a room of eight bulbs reaches all of them through five connections', () async {
      await start(maxConnections: 5);
      final ids = <String>[];
      for (var i = 0; i < 8; i++) {
        ids.add((await addBulb('b$i')).id);
      }
      final room = await home.createRoom('Big room', ids);
      await home.setRoomPower(room.id, true);
      for (var i = 0; i < 8; i++) {
        expect(central.bulbs['b$i']!.state.on, isTrue, reason: 'b$i');
      }
      expect(central.peakConnections, lessThanOrEqualTo(5));
    });
  });

  group('profiles', () {
    setUp(start);

    test('a fresh install has starter presets', () async {
      expect(home.profiles.map((p) => p.name), containsAll(['Relax', 'Read', 'Concentrate', 'Energise', 'Nightlight']));
    });

    test('a scene captures each light and brings each back', () async {
      final a = await addBulb('a');
      final b = await addBulb('b');
      await home.send(a.id, const LightCommand(on: true, brightness: 50, color: XyColor(0.6, 0.3)));
      await home.send(b.id, const LightCommand(on: true, brightness: 200, color: WhiteColor(400)));
      final scene = await home.saveScene('Movie night', [a.id, b.id]);
      await home.sendAll([a.id, b.id], const LightCommand(on: false));
      await home.applyProfile(scene.id);
      expect(central.bulbs['a']!.state.brightness, 50);
      expect(central.bulbs['a']!.state.color, const XyColor(0.6, 0.3));
      expect(central.bulbs['b']!.state.color, const WhiteColor(400));
      expect(central.bulbs['b']!.state.on, isTrue);
    });

    test('a preset applies one look to any lights', () async {
      final a = await addBulb('a');
      final b = await addBulb('b');
      final preset = await home.savePreset(
        'Sunset',
        const LightState(on: true, brightness: 180, color: XyColor(0.55, 0.4)),
      );
      await home.applyProfile(preset.id, to: [a.id, b.id]);
      expect(central.bulbs['a']!.state.color, const XyColor(0.55, 0.4));
      expect(central.bulbs['b']!.state.brightness, 180);
    });

    test('a colour preset on a white ambiance bulb becomes the closest white', () async {
      final t = await addBulb('t', model: 'LTA001');
      final preset = await home.savePreset(
        'Warm',
        const LightState(on: true, brightness: 100, color: XyColor(0.5, 0.41)),
      );
      final approximated = await home.applyProfile(preset.id, to: [t.id]);
      expect(approximated, 1);
      final color = central.bulbs['t']!.state.color;
      expect(color, isA<WhiteColor>());
      expect((color as WhiteColor).mireds, inInclusiveRange(400, 500));
    });

    test('profiles can be renamed, deleted and restored, and persist', () async {
      final preset = await home.savePreset('Sunset', const LightState(on: true, brightness: 180));
      await home.updateProfile(preset.copyWith(name: 'Dusk'));
      final again = build();
      await again.load();
      expect(again.profiles.map((p) => p.name), contains('Dusk'));
      await home.deleteProfile(preset.id);
      expect(home.profiles.map((p) => p.name), isNot(contains('Dusk')));
      await home.restoreProfile(preset.copyWith(name: 'Dusk'));
      expect(home.profiles.map((p) => p.name), contains('Dusk'));
    });

    test('removing a light drops it from scenes', () async {
      final a = await addBulb('a');
      final scene = await home.saveScene('Solo', [a.id]);
      await home.remove(a.id);
      expect(home.profiles.firstWhere((p) => p.id == scene.id).states, isEmpty);
    });
  });

  group('quick actions', () {
    setUp(start);

    test('all off switches every light off', () async {
      final a = await addBulb('a');
      final b = await addBulb('b');
      await home.sendAll([a.id, b.id], const LightCommand(on: true));
      await home.allOff();
      expect(central.bulbs['a']!.state.on, isFalse);
      expect(central.bulbs['b']!.state.on, isFalse);
    });

    test('profiles can be marked as favourites', () async {
      final preset = await home.savePreset('Sunset', const LightState(on: true));
      await home.toggleProfileFavorite(preset.id);
      expect(home.favoriteProfiles.map((p) => p.id), contains(preset.id));
      await home.toggleProfileFavorite(preset.id);
      expect(home.favoriteProfiles.map((p) => p.id), isNot(contains(preset.id)));
    });
  });

  test('profile JSON round trips', () {
    const p = Profile(
      id: 'p',
      name: 'X',
      states: {'*': LightState(on: true, color: WhiteColor(300))},
      favorite: true,
    );
    final back = Profile.fromJson(p.toJson());
    expect(back.states['*'], p.states['*']);
    expect(back.favorite, isTrue);
    expect(back.isPreset, isTrue);
  });
}
