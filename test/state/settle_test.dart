import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';

void main() {
  late SimulatedBleCentral central;
  late SimulatedBridge bridge;
  late HomeController home;
  late DateTime now;

  setUp(() async {
    now = DateTime(2026, 10, 23, 20);
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    bridge = SimulatedBridge()..addLight(SimulatedBridgeLight(name: 'Sofa'));
    home = HomeController(
      AppServices.simulated(central: central, bridge: bridge, store: MemoryHomeStore()),
      clock: () => now,
    );
    await home.load();
  });

  Future<Light> addBulb() async {
    central.addBulb(SimulatedHueBulb(id: 'a', state: const LightState(on: true, brightness: 254)));
    final found = await home.scanBluetooth().first;
    return home.addBluetoothLight(found);
  }

  test('reports from a bulb that is still fading do not undo the new brightness', () async {
    final light = await addBulb();
    await home.setBrightness(light.id, 50);
    // The bulb fades from 254 to 50 and reports where it is along the way.
    central.bulbs['a']!.report(const LightState(on: true, brightness: 150));
    await pumpEventQueue();
    expect(home.light(light.id)!.state.brightness, 50);
  });

  test('once the light has settled, changes made elsewhere show again', () async {
    final light = await addBulb();
    await home.setBrightness(light.id, 50);
    now = now.add(const Duration(seconds: 5));
    central.bulbs['a']!.changeLocally(const LightCommand(brightness: 90));
    await pumpEventQueue();
    expect(home.light(light.id)!.state.brightness, 90);
  });

  test('a bridge poll during the fade does not undo the new brightness', () async {
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2');
    final sofa = home.lights.single.id;
    await home.setBrightness(sofa, 50);
    bridge.lights['1']!.state = const LightState(on: true, brightness: 200);
    await home.refresh();
    expect(home.light(sofa)!.state.brightness, 50);
    now = now.add(const Duration(seconds: 5));
    await home.refresh();
    expect(home.light(sofa)!.state.brightness, 200);
  });
}
