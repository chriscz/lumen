import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';

void main() {
  const latency = Duration(milliseconds: 60);
  late SimulatedBleCentral central;
  late SimulatedBridge bridge;
  late HomeController home;

  setUp(() async {
    central = SimulatedBleCentral(scanDelay: Duration.zero, latency: latency, maxConnections: 5);
    bridge = SimulatedBridge();
    for (var i = 1; i <= 6; i++) {
      bridge.addLight(SimulatedBridgeLight(name: 'Bridge $i'));
    }
    bridge
      ..addGroup('Lounge', ['1', '2', '3', '4'])
      ..addGroup('Den', ['5', '6']);
    home = HomeController(AppServices.simulated(central: central, bridge: bridge, store: MemoryHomeStore()));
    await home.load();
  });

  Future<List<String>> addBulbs(int n) async {
    final ids = <String>[];
    for (var i = 0; i < n; i++) {
      central.addBulb(SimulatedHueBulb(id: 'b$i', name: 'Bulb $i'));
      final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == 'b$i');
      ids.add((await home.addBluetoothLight(found)).id);
    }
    return ids;
  }

  test('connected Bluetooth bulbs are written in parallel', () async {
    final ids = await addBulbs(5);
    final room = await home.createRoom('Study', ids);
    final watch = Stopwatch()..start();
    await home.setRoomPower(room.id, true);
    watch.stop();
    expect(central.bulbs.values.every((b) => b.state.on == true), isTrue);
    // One write each, in parallel: about one latency, not five.
    expect(watch.elapsed, lessThan(latency * 3));
  });

  test('eight bulbs through five connections stay within the budget and all switch', () async {
    final ids = await addBulbs(8);
    final room = await home.createRoom('Big', ids);
    await home.setRoomPower(room.id, true);
    expect(central.bulbs.values.every((b) => b.state.on == true), isTrue);
    expect(central.peakConnections, lessThanOrEqualTo(5));
  });

  test('a bridge room is switched with one group action', () async {
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2');
    final lounge = home.rooms.firstWhere((r) => r.name == 'Lounge');
    bridge.requests.clear();
    await home.setRoomPower(lounge.id, true);
    expect(bridge.requests, ['PUT /groups/1/action']);
    expect([
      for (final id in ['1', '2', '3', '4']) bridge.lights[id]!.state.on,
    ], everyElement(isTrue));
    expect(bridge.lights['5']!.state.on, isFalse);
    expect(home.lightsIn(lounge.id).every((l) => l.isOn), isTrue);
  });

  test('all off uses the all-lights group of each bridge', () async {
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2');
    await home.sendAll(home.lights.map((l) => l.id), const LightCommand(on: true));
    bridge.requests.clear();
    await home.allOff();
    expect(bridge.requests, ['PUT /groups/0/action']);
    expect(bridge.lights.values.every((l) => l.state.on == false), isTrue);
  });

  test('a partial selection falls back to per-light calls', () async {
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2');
    bridge.requests.clear();
    final some = home.lights.where((l) => l.name == 'Bridge 1' || l.name == 'Bridge 5').map((l) => l.id);
    await home.sendAll(some, const LightCommand(on: true));
    expect(bridge.requests..sort(), ['PUT /lights/1/state', 'PUT /lights/5/state']);
  });

  test('sendEach sends lights with the same command together, and each other command on its own', () async {
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2');
    bridge.requests.clear();
    final lounge = home.rooms.firstWhere((r) => r.name == 'Lounge');
    const warm = LightCommand(on: true, color: WhiteColor(400));
    await home.sendEach({
      for (final l in home.lightsIn(lounge.id)) l.id: warm,
      HomeController.bridgeLightId(bridge.id, '5'): const LightCommand(on: true),
    });
    expect(bridge.requests..sort(), ['PUT /groups/1/action', 'PUT /lights/5/state']);
    expect(bridge.lights['1']!.state.color, const WhiteColor(400));
    expect(bridge.lights['5']!.state.on, isTrue);
  });

  test('a failed group action rolls back every member', () async {
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2');
    final lounge = home.rooms.firstWhere((r) => r.name == 'Lounge');
    bridge.failAll = true;
    await home.setRoomPower(lounge.id, true);
    expect(home.lightsIn(lounge.id).every((l) => !l.isOn), isTrue);
  });

  test('dragging a room slider coalesces group actions', () async {
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2');
    final lounge = home.rooms.firstWhere((r) => r.name == 'Lounge');
    bridge.requests.clear();
    await Future.wait([for (var b = 10; b <= 250; b += 10) home.setRoomBrightness(lounge.id, b)]);
    expect(bridge.requests.length, lessThan(5));
    expect(bridge.lights['1']!.state.brightness, 250);
  });
}
