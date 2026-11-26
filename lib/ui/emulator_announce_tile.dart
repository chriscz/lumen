// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../emulator/bridge_emulator.dart';

/// The "Announce on Wi-Fi" switch, with whether the bridge is announcing
/// itself (mDNS and SSDP) or why not.
class EmulatorAnnounceTile extends StatelessWidget {
  const EmulatorAnnounceTile({super.key, required this.emulator});

  final BridgeEmulator emulator;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const ValueKey('emulator-announce-switch'),
    secondary: Icon(emulator.announcing ? Icons.wifi_tethering_rounded : Icons.portable_wifi_off_rounded),
    title: const Text('Announce on Wi-Fi'),
    subtitle: Text(emulator.announcement ?? 'Lets apps on this Wi-Fi find the bridge (mDNS and SSDP).'),
    value: emulator.announce,
    onChanged: emulator.loaded ? emulator.setAnnounce : null,
  );
}
