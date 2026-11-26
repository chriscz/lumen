import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';

void main() {
  late SimulatedBleCentral central;
  late MemoryHomeStore store;
  late HomeController home;
  late String cluster;

  HomeController build() =>
      HomeController(AppServices.simulated(central: central, bridge: SimulatedBridge(), store: store));

  setUp(() async {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    store = MemoryHomeStore();
    home = build();
    await home.load();
    for (final id in ['a', 'b']) {
      central.addBulb(SimulatedHueBulb(id: id));
      final found = await home.scanBluetooth().firstWhere((x) => x.deviceId == id);
      await home.addBluetoothLight(found);
    }
    cluster = (await home.createRoom('Pair', ['ble:a', 'ble:b'], linked: true)).id;
  });

  SimulatedHueBulb bulb(String id) => central.bulbs[id]!;

  test('cluster commands reach every attached member and become the cluster state', () async {
    await home.setRoomPower(cluster, true);
    await home.setRoomBrightness(cluster, 100);
    expect([bulb('a').state.brightness, bulb('b').state.brightness], [100, 100]);
    expect(home.clusterLight(home.rooms.single).state.brightness, 100);
  });

  test('touching a member on its own detaches it, and the cluster then skips it', () async {
    await home.setRoomPower(cluster, true);
    await home.setPower('ble:a', false);
    expect(home.isDetached('ble:a'), isTrue);
    await home.setRoomBrightness(cluster, 60);
    expect(bulb('a').state.on, isFalse);
    expect(bulb('b').state.brightness, 60);
  });

  test('rejoining a member gives it the cluster settings again', () async {
    await home.setRoomPower(cluster, true);
    await home.setRoomColor(cluster, const XyColor(0.6, 0.3));
    await home.setColor('ble:a', const WhiteColor(400));
    await home.rejoin(cluster, 'ble:a');
    expect(home.isDetached('ble:a'), isFalse);
    expect(bulb('a').state.color, const XyColor(0.6, 0.3));
    expect(bulb('a').state.on, isTrue);
  });

  test('reset brings every detached member back to the cluster settings', () async {
    await home.setRoomPower(cluster, true);
    await home.setRoomBrightness(cluster, 200);
    await home.setBrightness('ble:a', 20);
    await home.setPower('ble:b', false);
    expect(home.detachedIn(cluster), {'ble:a', 'ble:b'});
    await home.resetCluster(cluster);
    expect(home.detachedIn(cluster), isEmpty);
    expect([bulb('a').state.brightness, bulb('b').state.brightness], [200, 200]);
    expect(bulb('b').state.on, isTrue);
  });

  test('all off switches a cluster off too, keeping its look for the next on', () async {
    await home.setRoomPower(cluster, true);
    await home.setRoomBrightness(cluster, 80);
    await home.setPower('ble:a', true);
    await home.allOff();
    expect(home.clusterLight(home.rooms.single).isOn, isFalse);
    expect(home.rooms.single.clusterState.brightness, 80);
    expect([bulb('a').state.on, bulb('b').state.on], [false, false]);
    await home.setRoomPower(cluster, true);
    expect(bulb('b').state.on, isTrue);
  });

  test('lights in a plain group do not detach', () async {
    final group = await home.createRoom('Plain', ['ble:a', 'ble:b']);
    await home.setPower('ble:a', true);
    expect(home.detachedIn(group.id), isEmpty);
  });

  test('cluster settings and detached members survive a restart', () async {
    await home.setRoomPower(cluster, true);
    await home.setRoomBrightness(cluster, 150);
    await home.setPower('ble:a', false);
    final again = build();
    await again.load();
    expect(again.isDetached('ble:a'), isTrue);
    expect(again.clusterLight(again.rooms.single).state.brightness, 150);
  });
}
