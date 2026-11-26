// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

/// Plain notes on running the phone as a Hue Bridge: how others find it,
/// why Android puts it to sleep and what the settings do about that.
class BridgeHelpScreen extends StatelessWidget {
  const BridgeHelpScreen({super.key});

  static const title = 'Running Lumen as a bridge';

  static const sections = [
    (
      'How other devices find it',
      [
        'With Announce on Wi-Fi on, the bridge says where it is in two ways: mDNS (as _hue._tcp, which newer Hue apps '
            'look for) and SSDP (the older UPnP search). Either can be switched off under Advanced.',
        'Android does not let apps use port 80, so the bridge listens on the first free port of 1818, 1919, 2020 '
            'and so on up to 2727. Lumen on another phone tries the ports 1818 to 2727 on an address, so it finds '
            'the bridge even when an announcement is missed.',
        'With announcing off, other devices can still reach the bridge by that port scan or by an address you '
            'type in.',
        'Apps that take an address with a port, such as Home Assistant, can be given it directly, for example '
            '192.168.1.20:1818. Settings shows the address in use.',
        'Giving this phone a fixed IP address in your router (a DHCP reservation) means that address keeps working.',
      ],
    ),
    (
      'Why Android puts apps to sleep',
      [
        'To save battery, Android stops apps you are not looking at: it freezes them in the background, and with '
            'the screen off for a while it dozes and holds back network access. The bridge lives inside Lumen, '
            'so when Lumen sleeps, the bridge stops answering.',
      ],
    ),
    (
      'What the settings do',
      [
        'Run in the background starts a foreground service while the bridge runs. It shows a quiet notification '
            '(Lumen bridge running, with the address and how many apps are active) and keeps Android from freezing '
            'Lumen. Tap the notification to open the app. The service runs even if you do not allow notifications.',
        'Battery optimisation opens Android\'s list of apps. Set Lumen to Unrestricted (or Not optimised) so '
            'Android does not stop it in the background.',
        'Stay fully awake while charging, under Advanced, keeps the processor and Wi-Fi fully awake while the '
            'phone is plugged in, and lets go when it is unplugged. It answers fastest but uses more power, so it '
            'is off by default.',
      ],
    ),
    (
      'Trade-offs',
      [
        'Without the charging option the phone still sleeps between requests, and a request to the bridge wakes '
            'it, so the first request after a quiet spell can take a moment longer.',
        'While the phone sleeps it may miss discovery messages, so another device may not find the bridge by '
            'searching. A fixed IP address and the port, typed in once, avoid that.',
        'Swiping Lumen away from the recent apps ends it, and the bridge with it.',
      ],
    ),
    (
      'Privacy',
      [
        'Everything stays on your local network. The bridge talks only to devices on the same Wi-Fi, and Lumen '
            'uses no cloud or third-party service for it. Only apps you pair with the link button can control '
            'your lights, and you can remove any of them in Settings.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: const ValueKey('bridge-help'),
      appBar: AppBar(title: const Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          for (final (heading, paragraphs) in sections) ...[
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text(heading, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
            ),
            for (final p in paragraphs)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(p, style: theme.textTheme.bodyMedium),
              ),
          ],
        ],
      ),
    );
  }
}
