import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/transport/bridge/bridge_ports.dart';

void main() {
  test('a phone bridge uses ten ports, 1818 then every 101 up to 2727', () {
    expect(BridgePorts.lan, [1818, 1919, 2020, 2121, 2222, 2323, 2424, 2525, 2626, 2727]);
  });

  test('clients look on port 80 first, then the phone bridge ports', () {
    expect(BridgePorts.probe, [80, ...BridgePorts.lan]);
  });
}
