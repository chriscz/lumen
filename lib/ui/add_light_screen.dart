// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/errors.dart';
import '../log/logger.dart';
import '../transport/ble/hue_ble_driver.dart';
import '../transport/bridge/lan_bridge_discovery.dart';
import 'home_scope.dart';
import 'settings_screen.dart';
import 'widgets/prompts.dart';

class AddLightScreen extends StatelessWidget {
  const AddLightScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Add light'),
        bottom: const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.bluetooth_searching_rounded), text: 'Bluetooth'),
            Tab(icon: Icon(Icons.router_rounded), text: 'Hue Bridge'),
          ],
        ),
      ),
      body: const TabBarView(children: [_BluetoothTab(), _BridgeTab()]),
    ),
  );
}

void _added(BuildContext context, String what) {
  final messenger = ScaffoldMessenger.of(context);
  Navigator.of(context).pop();
  messenger.show(what);
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message, {this.details, this.onRetry, this.onCopyDiagnostics});

  final String message;

  /// Raw detail, shown when debug logging is on.
  final String? details;
  final VoidCallback? onRetry;
  final VoidCallback? onCopyDiagnostics;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = TextStyle(color: scheme.onErrorContainer);
    return Card(
      key: const ValueKey('error-banner'),
      color: scheme.errorContainer,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: scheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(child: Text(message, style: text)),
              ],
            ),
            if (details != null)
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 8),
                child: SelectableText(details!, style: text.copyWith(fontFamily: 'monospace', fontSize: 12)),
              ),
            if (onRetry != null || onCopyDiagnostics != null)
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  if (onCopyDiagnostics != null)
                    TextButton(
                      key: const ValueKey('copy-diagnostics'),
                      onPressed: onCopyDiagnostics,
                      child: const Text('Copy diagnostics'),
                    ),
                  if (onRetry != null)
                    FilledButton.tonal(
                      key: const ValueKey('retry-add'),
                      onPressed: onRetry,
                      child: const Text('Retry'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// How to get a Hue bulb to accept this phone, in the order worth trying.
class _PairingHelpCard extends StatelessWidget {
  const _PairingHelpCard();

  static const steps = [
    (
      'Close the Hue app',
      'Swipe the official Hue app away from recent apps. A bulb connected to it does not accept another phone.',
    ),
    (
      'Make it discoverable',
      'In the Hue app open Settings, Voice assistants, Amazon Alexa (or Google Home), and tap Make discoverable. '
          'Then close the Hue app and add the bulb here within a minute or two.',
    ),
    (
      'Last resort: factory reset',
      'Switch the bulb off and on five times, about a second apart, ending on. It blinks to confirm. '
          'It gets a new Bluetooth address, so it must be added in the Hue app again too.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: ExpansionTile(
        key: const ValueKey('pairing-help'),
        leading: const Icon(Icons.help_outline_rounded),
        title: const Text("Can't add your bulb?"),
        subtitle: const Text('How to put a Hue bulb in pairing mode'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text(
            'A bulb that is already paired with this phone is listed under "Paired with this phone" '
            'and needs none of this.',
            style: theme.textTheme.bodySmall,
          ),
          for (final (i, (title, body)) in steps.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(radius: 14, child: Text('${i + 1}')),
              title: Text(title),
              subtitle: Text(body),
            ),
        ],
      ),
    );
  }
}

class _BluetoothTab extends StatefulWidget {
  const _BluetoothTab();

  @override
  State<_BluetoothTab> createState() => _BluetoothTabState();
}

class _BluetoothTabState extends State<_BluetoothTab> with AutomaticKeepAliveClientMixin {
  final List<DiscoveredBulb> _found = [];
  List<DiscoveredBulb> _known = const [];
  StreamSubscription<DiscoveredBulb>? _scan;
  String? _adding;
  LightError? _error;
  DiscoveredBulb? _failed;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_preparing && !_ready) {
      _preparing = true;
      _prepare();
    }
    // A fixed permission or Bluetooth turned on starts the scan.
    if (_ready && _scan == null && _adding == null && HomeScope.of(context).bluetoothIssue == null) {
      _scan = _startScan();
    }
  }

  bool _preparing = false;
  bool _ready = false;

  Future<void> _prepare() async {
    final home = HomeScope.read(context);
    final ok = await home.prepareBluetooth();
    if (!mounted) return;
    _loadKnown();
    setState(() => _ready = true);
    if (ok && _scan == null) _scan = _startScan();
  }

  Future<void> _loadKnown() async {
    final known = await HomeScope.read(context).knownBluetooth();
    if (mounted) setState(() => _known = known);
  }

  StreamSubscription<DiscoveredBulb> _startScan() => HomeScope.read(context).scanBluetooth().listen((b) {
    if (_found.any((f) => f.deviceId == b.deviceId)) return;
    setState(() => _found.add(b));
  }, onError: (Object e) => setState(() => _error = e is LightError ? e : LightUnreachable('$e')));

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  /// Adds [bulb] with the scan paused: connecting while scanning fails with
  /// GATT error 133 on many Android phones. On success the screen closes;
  /// otherwise the scan resumes and the found list stays.
  Future<void> _add(DiscoveredBulb bulb) async {
    final home = HomeScope.read(context);
    home.log.info(LogTag.ui, 'tapped add ${bulb.deviceId}');
    setState(() {
      _adding = bulb.deviceId;
      _error = null;
      _failed = null;
    });
    final scan = _scan;
    _scan = null;
    await scan?.cancel();
    var added = false;
    try {
      final light = await home.addBluetoothLight(bulb);
      added = true;
      if (mounted) _added(context, 'Added ${light.name}');
    } on LightError catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _failed = bulb;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _adding = null);
        if (!added) _scan ??= _startScan();
      }
    }
  }

  void _copyDiagnostics() {
    final home = HomeScope.read(context);
    Clipboard.setData(ClipboardData(text: home.log.tail(200)));
    ScaffoldMessenger.of(context).show('Diagnostics copied');
  }

  Widget _bulbTile(DiscoveredBulb bulb, {required bool paired}) => ListTile(
    key: ValueKey('bulb-${bulb.deviceId}'),
    leading: CircleAvatar(child: Icon(paired ? Icons.link_rounded : Icons.lightbulb_rounded)),
    title: Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(bulb.name, overflow: TextOverflow.ellipsis),
        if (bulb.openForBonding == true && !paired) ...[
          Chip(
            key: ValueKey('ready-to-pair-${bulb.deviceId}'),
            avatar: const Icon(Icons.check_circle_rounded, size: 16),
            label: const Text('Ready to pair'),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ],
    ),
    subtitle: Text(
      paired
          ? 'Paired with this phone, ${bulb.deviceId}'
          : (bulb.rssi == null ? bulb.deviceId : 'Signal ${bulb.rssi} dBm'),
    ),
    trailing: _adding == bulb.deviceId
        ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
        : const Icon(Icons.add_circle_outline_rounded),
    enabled: _adding == null,
    onTap: () => _add(bulb),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final home = HomeScope.of(context);
    final error = _error;
    final knownIds = {for (final k in _known) k.deviceId};
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (error != null)
          _ErrorBanner(
            error.message,
            details: home.debugLogging ? error.details : null,
            onRetry: _failed == null || _adding != null ? null : () => _add(_failed!),
            onCopyDiagnostics: _copyDiagnostics,
          ),
        if (_known.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Text('Paired with this phone', style: theme.textTheme.titleSmall),
          ),
          for (final bulb in _known) _bulbTile(bulb, paired: true),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Row(
            children: [
              const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Expanded(child: Text('Looking for Hue bulbs nearby', style: theme.textTheme.titleSmall)),
            ],
          ),
        ),
        for (final bulb in _found)
          if (!knownIds.contains(bulb.deviceId)) _bulbTile(bulb, paired: false),
        const _PairingHelpCard(),
      ],
    );
  }
}

/// What the search is doing, for the line under its spinner.
String discoveryStageText(StageStarted stage) => switch (stage.stage) {
  DiscoveryStage.known => 'Checking known bridges...',
  DiscoveryStage.mdns => 'Asking the network (mDNS, ${(stage.mdns ?? MdnsImplementation.builtIn).short})...',
  DiscoveryStage.ssdp => 'Searching with SSDP...',
  DiscoveryStage.sweep when stage.hosts == 0 => 'No Wi-Fi network to scan...',
  DiscoveryStage.sweep => 'Scanning ${stage.hosts} addresses on ${stage.ports} ports...',
};

/// How a search ended, with what it found.
String discoveryEndText(int found, {required bool stopped}) =>
    '${stopped ? 'Search stopped' : 'Search finished'}, '
    '${switch (found) {
      0 => 'no bridge',
      1 => '1 bridge',
      _ => '$found bridges',
    }} found';

class _BridgeTab extends StatefulWidget {
  const _BridgeTab();

  @override
  State<_BridgeTab> createState() => _BridgeTabState();
}

class _BridgeTabState extends State<_BridgeTab> with AutomaticKeepAliveClientMixin {
  final _host = TextEditingController();
  final List<FoundBridge> _found = [];
  StreamSubscription<DiscoveryEvent>? _search;
  StageStarted? _stage;
  bool _searching = false;
  bool _stopped = false;
  String? _pairing;
  String? _error;
  bool _cancelled = false;
  bool _started = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _startSearch();
    }
  }

  void _startSearch() {
    final home = HomeScope.read(context);
    if (!home.discoverySettings.anyOn) return;
    _search?.cancel();
    setState(() {
      _found.clear();
      _stage = null;
      _searching = true;
      _stopped = false;
    });
    _search = home.discoverBridges().listen((event) {
      if (!mounted) return;
      setState(() {
        switch (event) {
          case StageStarted():
            _stage = event;
          case BridgeFound(:final bridge):
            _found.add(bridge);
          case DiscoveryFinished():
            _searching = false;
        }
      });
    });
  }

  void _stopSearch() {
    _search?.cancel();
    _search = null;
    setState(() {
      _searching = false;
      _stopped = true;
    });
  }

  @override
  void dispose() {
    _cancelled = true;
    _search?.cancel();
    _host.dispose();
    super.dispose();
  }

  Future<void> _pair(String host) async {
    if (host.trim().isEmpty) return;
    setState(() {
      _pairing = host.trim();
      _error = null;
      _cancelled = false;
    });
    try {
      final account = await HomeScope.read(context).pairBridge(host.trim(), cancelled: () => _cancelled);
      if (mounted) _added(context, 'Paired ${account.name}');
    } on LightError catch (e) {
      if (mounted && !_cancelled) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _pairing = null);
    }
  }

  Widget _status(ThemeData theme) {
    final stage = _stage;
    if (_searching) {
      return ListTile(
        key: const ValueKey('discovery-searching'),
        leading: const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text(
          stage == null ? 'Looking for bridges...' : discoveryStageText(stage),
          key: const ValueKey('discovery-status'),
        ),
        trailing: TextButton(key: const ValueKey('discovery-stop'), onPressed: _stopSearch, child: const Text('Stop')),
      );
    }
    return ListTile(
      leading: const Icon(Icons.done_rounded),
      title: Text(discoveryEndText(_found.length, stopped: _stopped), key: const ValueKey('discovery-status')),
      subtitle: _found.isEmpty ? const Text('Enter its address below.') : null,
      trailing: TextButton(
        key: const ValueKey('discovery-again'),
        onPressed: _startSearch,
        child: const Text('Search again'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final home = HomeScope.of(context);
    if (_pairing != null) {
      return _LinkButtonPrompt(host: _pairing!, onCancel: () => setState(() => _cancelled = true));
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (_error != null) _ErrorBanner(_error!),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
          child: Text('Bridges on your network', style: theme.textTheme.titleSmall),
        ),
        if (!home.discoverySettings.anyOn)
          ListTile(
            key: const ValueKey('discovery-off'),
            leading: const Icon(Icons.search_off_rounded),
            title: const Text('Bridge discovery is off'),
            subtitle: const Text('Enter the bridge address below, or turn a discovery method on in Settings.'),
            trailing: TextButton(
              key: const ValueKey('discovery-settings'),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
              child: const Text('Settings'),
            ),
          )
        else
          _status(theme),
        for (final b in _found)
          ListTile(
            key: ValueKey('found-${b.id}'),
            leading: CircleAvatar(child: Icon(b.phone ? Icons.smartphone_rounded : Icons.router_rounded)),
            title: Text(b.name),
            subtitle: Text(b.phone ? '${b.address}, a phone acting as a bridge' : b.address),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _pair(b.address),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('bridge-host'),
                  controller: _host,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Bridge address',
                    hintText: '192.168.1.20',
                    helperText: 'Add :port for a phone acting as a bridge, such as 192.168.1.20:1818',
                  ),
                  onSubmitted: _pair,
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(onPressed: () => _pair(_host.text), child: const Text('Connect')),
            ],
          ),
        ),
      ],
    );
  }
}

class _LinkButtonPrompt extends StatelessWidget {
  const _LinkButtonPrompt({required this.host, required this.onCancel});

  final String host;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 1, end: 0),
              duration: const Duration(seconds: 30),
              builder: (context, v, _) =>
                  SizedBox.square(dimension: 120, child: CircularProgressIndicator(value: v, strokeWidth: 6)),
            ),
            const SizedBox(height: 24),
            Text('Press the link button', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Press the round link button on top of the bridge at $host. This app waits 30 seconds.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }
}
