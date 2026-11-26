// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../domain/home.dart';
import '../emulator/bridge_emulator.dart';
import '../emulator/emulator_settings.dart';
import '../log/logger.dart';
import 'bridge_help_screen.dart';
import 'emulator_announce_tile.dart';
import 'emulator_scope.dart';
import 'diagnostics_screen.dart';
import 'discovery_settings_section.dart';
import 'home_scope.dart';
import 'plugin_scope.dart';
import 'widgets/experimental_badge.dart';
import 'widgets/prompts.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// Lists a bridge's removed lights, each with a way back, and one for all.
  Future<void> _showRemoved(BuildContext context, String bridgeId) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final home = HomeScope.of(context);
      final bridge = home.bridges.firstWhere((b) => b.id == bridgeId);
      final removed = bridge.removedLights.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('Removed from ${bridge.name}', style: Theme.of(context).textTheme.titleMedium),
              subtitle: const Text('They are still on the bridge. Added back, they show in the app again.'),
            ),
            for (final MapEntry(key: lightId, value: name) in removed)
              ListTile(
                leading: const Icon(Icons.lightbulb_outline_rounded),
                title: Text(name),
                trailing: TextButton(
                  key: ValueKey('add-back-$lightId'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    home.addBridgeLightBack(bridgeId, lightId);
                  },
                  child: const Text('Add back'),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.tonal(
                key: const ValueKey('add-all-back'),
                onPressed: () {
                  Navigator.of(context).pop();
                  home.addAllBridgeLightsBack(bridgeId);
                },
                child: const Text('Add all back'),
              ),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _forget(BuildContext context, BridgeAccount bridge) async {
    final home = HomeScope.read(context);
    final ok = await confirm(
      context,
      title: 'Forget ${bridge.name}?',
      body: 'Its lights leave the app. To use them again, pair the bridge again.',
      action: 'Forget',
    );
    if (ok) await home.forgetBridge(bridge.id);
  }

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final theme = Theme.of(context);
    final ble = home.lights.where((l) => l.address.contains(':')).length;
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (home.services.demo)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: const ListTile(
                leading: Icon(Icons.science_rounded),
                title: Text('Demo mode'),
                subtitle: Text('Lights and the bridge are simulated. Build without DEMO to use real lights.'),
              ),
            ),
          header('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SegmentedButton<ThemeChoice>(
              segments: const [
                ButtonSegment(
                  value: ThemeChoice.system,
                  icon: Icon(Icons.brightness_auto_rounded),
                  label: Text('System'),
                ),
                ButtonSegment(value: ThemeChoice.dark, icon: Icon(Icons.dark_mode_rounded), label: Text('Dark')),
                ButtonSegment(value: ThemeChoice.light, icon: Icon(Icons.light_mode_rounded), label: Text('Light')),
              ],
              selected: {home.themeChoice},
              onSelectionChanged: (s) => home.setThemeChoice(s.first),
            ),
          ),
          header('Hue Bridges'),
          if (home.bridges.isEmpty)
            const ListTile(
              leading: Icon(Icons.router_outlined),
              title: Text('No bridge paired'),
              subtitle: Text('Add light, then Hue Bridge, to pair one.'),
            ),
          for (final b in home.bridges)
            ListTile(
              leading: const Icon(Icons.router_rounded),
              title: Text(b.name),
              subtitle: Text('${b.host}, ${home.lights.where((l) => l.bridgeId == b.id).length} lights'),
              trailing: IconButton(
                key: const ValueKey('forget-bridge'),
                tooltip: 'Forget bridge',
                icon: const Icon(Icons.link_off_rounded),
                onPressed: () => _forget(context, b),
              ),
            ),
          for (final b in home.bridges)
            if (b.removedLights.isNotEmpty)
              ListTile(
                key: ValueKey('bridge-removed-${b.id}'),
                contentPadding: const EdgeInsets.only(left: 72, right: 16),
                title: Text('${b.removedLights.length} removed ${b.removedLights.length == 1 ? 'light' : 'lights'}'),
                subtitle: Text('On ${b.name}, but not in the app. Tap to add them back.'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _showRemoved(context, b.id),
              ),
          header('Bridge discovery'),
          const DiscoverySettingsSection(),
          header('Bluetooth'),
          ListTile(
            leading: const Icon(Icons.bluetooth_rounded),
            title: Text('$ble Bluetooth ${ble == 1 ? 'bulb' : 'bulbs'}'),
            subtitle: const Text(
              'The app keeps up to seven bulbs connected and connects to others when you use them. '
              'Bulbs must be within a room or two of the phone.',
            ),
          ),
          if (PluginScope.maybeOf(context) case final plugins? when plugins.plugins.isNotEmpty) ...[
            header('Plugins'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Optional features. Experimental ones may change or go away. Switched off, a plugin puts back '
                'any lights it changed.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            for (final plugin in plugins.plugins) ...[
              SwitchListTile(
                key: ValueKey('plugin-${plugin.id}'),
                secondary: Icon(plugin.icon),
                title: Row(
                  children: [
                    Flexible(child: Text(plugin.name)),
                    if (plugin.experimental) ...[const SizedBox(width: 8), const ExperimentalBadge()],
                  ],
                ),
                subtitle: Text(plugin.description),
                value: plugins.isEnabled(plugin.id),
                onChanged: plugins.loaded ? (on) => plugins.setEnabled(plugin.id, on) : null,
              ),
              if (plugins.isEnabled(plugin.id)) ...plugin.settingsEntries(context),
            ],
          ],
          if (EmulatorScope.maybeOf(context) case final emulator?) ...[
            header('Act as a Hue Bridge'),
            _EmulatorSection(emulator: emulator),
          ],
          header('Diagnostics'),
          SwitchListTile(
            key: const ValueKey('debug-logging-switch'),
            secondary: const Icon(Icons.bug_report_outlined),
            title: const Text('Debug logging'),
            subtitle: const Text(
              'Log every Bluetooth and bridge step and keep the log between runs. '
              'Off, only the last 100 lines are kept.',
            ),
            value: home.debugLogging,
            onChanged: home.setDebugLogging,
          ),
          ListTile(
            key: const ValueKey('open-diagnostics'),
            leading: const Icon(Icons.receipt_long_rounded),
            title: const Text('Diagnostics'),
            subtitle: const Text('View, copy and share the log'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen())),
          ),
          header('About'),
          const ListTile(
            leading: Icon(Icons.info_outline_rounded),
            title: Text('Lumen 1.0'),
            subtitle: Text(
              'Controls Philips Hue lights over Bluetooth and the Hue Bridge local API. '
              'Not affiliated with Signify. Philips Hue is a trademark of Signify.',
            ),
          ),
        ],
      ),
    );
  }
}

/// Lets the phone act as a Hue Bridge for other apps on the Wi-Fi.
class _EmulatorSection extends StatelessWidget {
  const _EmulatorSection({required this.emulator});

  final BridgeEmulator emulator;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = emulator.linkButtonRemaining;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('bridge-emulator-switch'),
          secondary: const Icon(Icons.hub_rounded),
          title: const Text('Act as a Hue Bridge'),
          subtitle: const Text(
            'Other apps on this Wi-Fi can control the lights in Lumen as if they were on a Hue Bridge.',
          ),
          value: emulator.enabled,
          onChanged: emulator.loaded ? emulator.setEnabled : null,
        ),
        if (emulator.enabled) ...[
          if (emulator.url case final url?)
            ListTile(
              key: const ValueKey('emulator-address'),
              leading: const Icon(Icons.lan_rounded),
              title: SelectableText(url),
              subtitle: const Text('Enter this address in apps that do not find the bridge on their own.'),
            )
          else if (emulator.error case final error?)
            ListTile(
              key: const ValueKey('emulator-error'),
              leading: Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
              title: const Text('Not running'),
              subtitle: Text(error),
            )
          else
            const ListTile(
              key: ValueKey('emulator-starting'),
              leading: Icon(Icons.hourglass_top_rounded),
              title: Text('Starting'),
            ),
          EmulatorAnnounceTile(emulator: emulator),
          if (emulator.port != 80)
            Padding(
              key: const ValueKey('emulator-port-note'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Android does not let apps use port 80, so apps that only look there (such as Alexa or the Hue app) '
                'will not find this bridge; apps that take an address with a port, such as Home Assistant, will. '
                'Lumen on another phone tries the ports 1818 to 2727.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Padding(
            key: const ValueKey('emulator-link'),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: FilledButton.tonalIcon(
              key: const ValueKey('emulator-link-button'),
              onPressed: emulator.running ? emulator.pressLinkButton : null,
              icon: const Icon(Icons.radio_button_checked_rounded),
              label: Text(
                remaining > Duration.zero
                    ? 'Link button on, ${remaining.inSeconds + (remaining.inMilliseconds % 1000 > 0 ? 1 : 0)} s left'
                    : 'Press link button',
              ),
            ),
          ),
          if (emulator.appsSummary case final summary?)
            Padding(
              key: const ValueKey('emulator-apps-summary'),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(summary, style: theme.textTheme.bodyMedium),
            )
          else
            const ListTile(
              key: ValueKey('emulator-no-apps'),
              leading: Icon(Icons.devices_other_rounded),
              title: Text('No apps paired'),
              subtitle: Text('Press the link button, then pair from the other app within 30 seconds.'),
            ),
          for (final app in emulator.pairedApps)
            ListTile(
              key: ValueKey('paired-${app.username}'),
              leading: Icon(
                Icons.devices_other_rounded,
                color: emulator.isActive(app) ? theme.colorScheme.primary : null,
              ),
              title: Text(app.devicetype),
              subtitle: Text('${emulator.lastSeenOf(app)}. Paired ${LogEntry.date(app.created.toLocal())}.'),
              trailing: IconButton(
                key: ValueKey('revoke-${app.username}'),
                tooltip: 'Remove ${app.devicetype}',
                icon: const Icon(Icons.link_off_rounded),
                onPressed: () => _remove(context, app),
              ),
            ),
          if (emulator.backgroundSupported) ...[
            SwitchListTile(
              key: const ValueKey('emulator-background-switch'),
              secondary: const Icon(Icons.nightlight_round),
              title: const Text('Run in the background'),
              subtitle: const Text(
                'Keeps the bridge listening with the screen off, with a quiet notification while it runs.',
              ),
              value: emulator.background,
              onChanged: emulator.setBackground,
            ),
            ListTile(
              key: const ValueKey('emulator-battery'),
              leading: const Icon(Icons.battery_saver_rounded),
              title: const Text('Battery optimisation'),
              subtitle: const Text(
                'Android may still put Lumen to sleep. Set Lumen to Unrestricted so the bridge keeps answering.',
              ),
              trailing: const Icon(Icons.open_in_new_rounded),
              onTap: emulator.openBatterySettings,
            ),
          ],
          _AdvancedFold(emulator: emulator),
        ],
        ListTile(
          key: const ValueKey('emulator-help'),
          leading: const Icon(Icons.help_outline_rounded),
          title: const Text(BridgeHelpScreen.title),
          subtitle: const Text('How others find it, staying awake, and privacy.'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BridgeHelpScreen())),
        ),
      ],
    );
  }

  Future<void> _remove(BuildContext context, PairedApp app) async {
    final ok = await confirm(
      context,
      title: 'Remove ${app.devicetype}?',
      body: 'It can no longer control the lights in Lumen. To use it again, pair it again.',
      action: 'Remove',
    );
    if (ok) await emulator.revoke(app.username);
  }
}

/// The emulator's less used controls, closed until opened: each discovery
/// mechanism, which mDNS responder to use, and staying awake on charge.
class _AdvancedFold extends StatelessWidget {
  const _AdvancedFold({required this.emulator});

  final BridgeEmulator emulator;

  @override
  Widget build(BuildContext context) {
    final announce = emulator.announce;
    return ExpansionTile(
      key: const ValueKey('bridge-advanced'),
      leading: const Icon(Icons.tune_rounded),
      title: const Text('Advanced'),
      subtitle: const Text('Discovery mechanisms and power'),
      children: [
        SwitchListTile(
          key: const ValueKey('emulator-mdns-switch'),
          title: const Text('mDNS'),
          subtitle: const Text('Answers apps that look for _hue._tcp, such as the newer Hue apps.'),
          value: emulator.mdnsEnabled,
          onChanged: announce ? emulator.setMdnsEnabled : null,
        ),
        if (emulator.systemMdnsAvailable)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('mDNS implementation'),
                const SizedBox(height: 8),
                SegmentedButton<MdnsImplementation>(
                  key: const ValueKey('emulator-mdns-implementation'),
                  segments: const [
                    ButtonSegment(value: MdnsImplementation.system, label: Text('Android (system)')),
                    ButtonSegment(value: MdnsImplementation.builtIn, label: Text('Built-in')),
                  ],
                  selected: {emulator.mdnsImplementation},
                  onSelectionChanged: announce && emulator.mdnsEnabled
                      ? (choice) => emulator.setMdnsImplementation(choice.single)
                      : null,
                ),
              ],
            ),
          ),
        SwitchListTile(
          key: const ValueKey('emulator-ssdp-switch'),
          title: const Text('SSDP'),
          subtitle: const Text('Answers UPnP searches on port 1900, as older apps send.'),
          value: emulator.ssdpEnabled,
          onChanged: announce ? emulator.setSsdpEnabled : null,
        ),
        if (emulator.backgroundSupported)
          SwitchListTile(
            key: const ValueKey('emulator-stay-awake-switch'),
            title: const Text('Stay fully awake while charging'),
            subtitle: const Text('Answers fastest while plugged in, at the cost of more power.'),
            value: emulator.stayAwakeWhileCharging,
            onChanged: emulator.setStayAwakeWhileCharging,
          ),
      ],
    );
  }
}
