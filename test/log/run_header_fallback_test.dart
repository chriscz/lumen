// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

// A file of its own: package_info_plus caches its first answer for the
// whole isolate, so the failure has to come before any mocked value.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/log/app_logging.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/sim/simulated_ble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an app version that cannot be read is logged as unknown, and the rest still follows', () async {
    final log = Logger.memory();
    await AppLogging.logRunHeader(log, SimulatedBleCentral(), android: false);
    final lines = log.entries.single.message.split('\n');
    expect(lines.first, 'Lumen run started');
    expect(lines[1], startsWith('App: unknown ('));
    expect(lines, contains('Build: debug'));
    expect(lines, contains('Bluetooth: poweredOn'));
  });
}
