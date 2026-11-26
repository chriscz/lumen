// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../domain/discovery_settings.dart';
import 'home_scope.dart';

/// How Add light looks for bridges: a summary, and the methods and the
/// mDNS implementation folded away under Advanced.
class DiscoverySettingsSection extends StatelessWidget {
  const DiscoverySettingsSection({super.key});

  static const _subtitles = {
    DiscoveryStage.known: 'Try the addresses of paired bridges first',
    DiscoveryStage.mdns: 'Ask the network for Hue Bridges by name (_hue._tcp)',
    DiscoveryStage.ssdp: 'Ask UPnP devices on the network to answer',
    DiscoveryStage.sweep: 'Try every address of the Wi-Fi network on the bridge ports. Slowest.',
  };

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final settings = home.discoverySettings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const ValueKey('discovery-summary'),
          leading: const Icon(Icons.travel_explore_rounded),
          title: Text(settings.summary),
          subtitle: const Text('Lumen looks for bridges on this Wi-Fi only, never through the internet.'),
        ),
        ExpansionTile(
          key: const ValueKey('discovery-advanced'),
          title: const Text('Advanced'),
          children: [
            for (final stage in DiscoveryStage.values) ...[
              SwitchListTile(
                key: ValueKey('discovery-${stage.name}'),
                title: Text(stage.label),
                subtitle: Text(_subtitles[stage]!),
                value: settings.enabled.contains(stage),
                onChanged: (on) => home.setDiscoveryStage(stage, on),
              ),
              if (stage == DiscoveryStage.mdns && home.hasAndroidMdns)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('mDNS implementation', style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 8),
                      SegmentedButton<MdnsImplementation>(
                        key: const ValueKey('mdns-implementation'),
                        segments: [
                          for (final m in MdnsImplementation.values) ButtonSegment(value: m, label: Text(m.label)),
                        ],
                        selected: {home.mdnsImplementation},
                        onSelectionChanged: (s) => home.setMdnsImplementation(s.first),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ],
    );
  }
}
