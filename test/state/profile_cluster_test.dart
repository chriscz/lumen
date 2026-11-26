import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';

void main() {
  late SimulatedBleCentral central;
  late HomeController home;
  late String cluster;

  setUp(() async {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    home = HomeController(AppServices.simulated(central: central, bridge: SimulatedBridge(), store: MemoryHomeStore()));
    await home.load();
    for (final id in ['a', 'b', 'c']) {
      central.addBulb(SimulatedHueBulb(id: id));
      final found = await home.scanBluetooth().firstWhere((x) => x.deviceId == id);
      await home.addBluetoothLight(found);
    }
    cluster = (await home.createRoom('Pair', ['ble:a', 'ble:b'], linked: true)).id;
    await home.setRoomPower(cluster, true);
  });

  Light clusterLight() => home.clusterLight(home.rooms.single);

  test('a preset applied to every light updates the linked light too', () async {
    final preset = await home.savePreset(
      'Sunset',
      const LightState(on: true, brightness: 90, color: XyColor(0.55, 0.4)),
    );
    await home.applyProfile(preset.id);
    expect(clusterLight().state.brightness, 90);
    expect(clusterLight().state.color, const XyColor(0.55, 0.4));
    expect(home.detachedIn(cluster), isEmpty);
  });

  test('a scene that gives the members different looks detaches them', () async {
    await home.send('ble:a', const LightCommand(on: true, brightness: 40));
    await home.send('ble:b', const LightCommand(on: true, brightness: 200));
    final scene = await home.saveScene('Split', ['ble:a', 'ble:b']);
    await home.setRoomBrightness(cluster, 120);
    await home.applyProfile(scene.id);
    expect(home.detachedIn(cluster), {'ble:a', 'ble:b'});
  });

  test('a preset applied to one member detaches only that member', () async {
    final preset = await home.savePreset('Dim', const LightState(on: true, brightness: 10));
    await home.applyProfile(preset.id, to: ['ble:a']);
    expect(home.detachedIn(cluster), {'ble:a'});
    expect(central.bulbs['b']!.state.brightness, isNot(10));
  });

  test('a preset applied to the linked light reaches its attached members and becomes its look', () async {
    await home.setPower('ble:b', false); // b detaches
    final preset = await home.savePreset('Read', const LightState(on: true, brightness: 250, color: WhiteColor(300)));
    await home.applyProfileToCluster(preset.id, cluster);
    expect(central.bulbs['a']!.state.brightness, 250);
    expect(central.bulbs['b']!.state.on, isFalse, reason: 'detached members keep their own look');
    expect(clusterLight().state.brightness, 250);
    expect(central.bulbs['c']!.state.on, isNot(true));
  });

  test('profiles for one light: presets, and scenes that include it', () async {
    final scene = await home.saveScene('Only a', ['ble:a']);
    final forA = home.profilesFor('ble:a').map((p) => p.id);
    final forC = home.profilesFor('ble:c').map((p) => p.id);
    expect(forA, contains(scene.id));
    expect(forC, isNot(contains(scene.id)));
    expect(forC, isNotEmpty, reason: 'starter presets apply to any light');
  });
}
