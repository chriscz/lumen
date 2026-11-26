// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/transport/bridge/lan_bridge_discovery.dart';
import 'package:lumen/ui/add_light_screen.dart';

void main() {
  test('each stage has a line saying what the search does', () {
    expect(discoveryStageText(const StageStarted(DiscoveryStage.known)), 'Checking known bridges...');
    expect(
      discoveryStageText(const StageStarted(DiscoveryStage.mdns, mdns: MdnsImplementation.android)),
      'Asking the network (mDNS, Android)...',
    );
    expect(discoveryStageText(const StageStarted(DiscoveryStage.mdns)), 'Asking the network (mDNS, built-in)...');
    expect(discoveryStageText(const StageStarted(DiscoveryStage.ssdp)), 'Searching with SSDP...');
    expect(
      discoveryStageText(const StageStarted(DiscoveryStage.sweep, hosts: 254, ports: 11)),
      'Scanning 254 addresses on 11 ports...',
    );
    expect(discoveryStageText(const StageStarted(DiscoveryStage.sweep)), 'No Wi-Fi network to scan...');
  });

  test('the end of a search says how many bridges it found', () {
    expect(discoveryEndText(0, stopped: false), 'Search finished, no bridge found');
    expect(discoveryEndText(1, stopped: false), 'Search finished, 1 bridge found');
    expect(discoveryEndText(2, stopped: true), 'Search stopped, 2 bridges found');
  });
}
