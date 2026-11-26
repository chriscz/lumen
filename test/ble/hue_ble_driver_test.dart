import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/transport/ble/hue_ble_driver.dart';

void main() {
  late SimulatedBleCentral central;
  late HueBleDriver driver;

  setUp(() {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    driver = HueBleDriver(central);
  });

  test('discovers advertising Hue bulbs in range', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', name: 'Desk'));
    central.addBulb(SimulatedHueBulb(id: 'aa:02', name: 'Far', inRange: false));
    final found = await driver.discover().take(1).toList();
    expect(found.single.deviceId, 'aa:01');
    expect(found.single.name, 'Desk');
  });

  test('adding a bulb in pairing mode bonds and reads its state and kind', () async {
    final bulb = central.addBulb(
      SimulatedHueBulb(
        id: 'aa:01',
        name: 'Desk',
        model: 'LTA001',
        state: const LightState(on: true, brightness: 100, color: WhiteColor(300)),
      ),
    );
    final info = await driver.add('aa:01');
    expect(bulb.bonded, isTrue);
    expect(info.name, 'Desk');
    expect(info.kind, LightKind.ambiance);
    expect(info.state, const LightState(on: true, brightness: 100, color: WhiteColor(300)));
  });

  test('adding a bulb that is not in pairing mode fails with a clear error', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', pairingMode: false));
    await expectLater(driver.add('aa:01'), throwsA(isA<NotInPairingMode>()));
  });

  test('send writes one TLV record set to the control characteristic', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    await driver.add('aa:01');
    await driver.send('aa:01', const LightCommand(on: false, brightness: 42));
    expect(bulb.writes.last.characteristic, HueGatt.control);
    expect(bulb.writes.last.value, [0x01, 0x01, 0x00, 0x02, 0x01, 42]);
    expect(bulb.state.on, isFalse);
    expect(bulb.state.brightness, 42);
  });

  test('send reconnects when the bulb dropped the connection', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    await driver.add('aa:01');
    central.dropConnection('aa:01');
    await driver.send('aa:01', const LightCommand(on: true));
    expect(bulb.state.on, isTrue);
  });

  test('send to a bulb out of range fails with LightUnreachable', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    await driver.add('aa:01');
    central.dropConnection('aa:01');
    bulb.inRange = false;
    await expectLater(driver.send('aa:01', const LightCommand(on: true)), throwsA(isA<LightUnreachable>()));
  });

  test('reports changes made elsewhere, for example by a wall switch', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    await driver.add('aa:01');
    final next = driver.reports.first;
    bulb.changeLocally(const LightCommand(on: false));
    final report = await next;
    expect(report.deviceId, 'aa:01');
    expect(report.state.on, isFalse);
  });

  test('keeps at most maxConnections open and evicts the least recently used', () async {
    final limited = HueBleDriver(central, maxConnections: 2);
    for (final id in ['a', 'b', 'c']) {
      central.addBulb(SimulatedHueBulb(id: id));
      await limited.add(id);
    }
    expect(central.connected, {'b', 'c'});
    await limited.send('a', const LightCommand(on: true));
    expect(central.connected, {'c', 'a'});
  });

  test('keeps up to seven links open by default, as most Android controllers allow', () async {
    for (var i = 0; i < 8; i++) {
      central.addBulb(SimulatedHueBulb(id: 'b$i'));
      await driver.add('b$i');
    }
    expect(driver.maxConnections, 7);
    expect(central.connected, {for (var i = 1; i < 8; i++) 'b$i'});
  });

  test('a phone that allows fewer links than the budget closes the least recently used one', () async {
    central = SimulatedBleCentral(scanDelay: Duration.zero, maxConnections: 3);
    driver = HueBleDriver(central);
    for (final id in ['a', 'b', 'c', 'd']) {
      central.addBulb(SimulatedHueBulb(id: id));
      await driver.add(id);
    }
    expect(central.connected, {'b', 'c', 'd'});
    await driver.send('a', const LightCommand(on: true));
    expect(central.connected, {'c', 'd', 'a'});
    expect(central.bulbs['a']!.state.on, isTrue);
    expect(central.peakConnections, 3);
  });

  test('a bulb out of range does not close other links', () async {
    central = SimulatedBleCentral(scanDelay: Duration.zero, maxConnections: 3);
    driver = HueBleDriver(central);
    for (final id in ['a', 'b']) {
      central.addBulb(SimulatedHueBulb(id: id));
      await driver.add(id);
    }
    central.addBulb(SimulatedHueBulb(id: 'far', inRange: false));
    await expectLater(driver.send('far', const LightCommand(on: true)), throwsA(isA<LightUnreachable>()));
    expect(central.connected, {'a', 'b'});
  });

  test('a bulb that is already bonded can be added outside pairing mode', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', pairingMode: false, bonded: true));
    final info = await driver.add('aa:01');
    expect(info.name, isNotEmpty);
  });
}
