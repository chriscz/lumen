// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../log/logger.dart';
import '../state/home_controller.dart';
import 'bridge_api.dart';
import 'bridge_background.dart';
import 'bridge_extensions.dart';
import 'bridge_server.dart';
import 'emulator_settings.dart';
import 'mdns_responder.dart';

/// Lets the phone act as a Hue Bridge: holds the emulator's settings, runs
/// the server while it is switched on, keeps it running in the background
/// where the platform allows, and saves what clients pair. The settings
/// screen watches it.
class BridgeEmulator extends ChangeNotifier {
  BridgeEmulator(this.home, {DateTime Function()? clock, BridgeExtensions? extensions})
    : _clock = clock ?? DateTime.now,
      extensions = extensions ?? BridgeExtensions();

  final HomeController home;

  /// The plugins' own APIs, served beside the Hue API.
  final BridgeExtensions extensions;
  final DateTime Function() _clock;

  EmulatorSettings? _settings;
  BridgeApi? _api;
  EmulatorServer? _server;
  Timer? _countdown;
  Timer? _minute;
  bool _disposed = false;

  /// What the background service was last told, or null while it is off.
  (String, bool)? _service;

  bool get loaded => _settings != null;
  EmulatorSettings get settings => _settings!;
  BridgeApi get api => _api!;
  bool get enabled => _settings?.enabled ?? false;

  bool get running => _server?.running ?? false;
  List<String> get addresses => _server?.addresses ?? const [];
  int? get port => _server?.port;
  bool get ssdp => running && (_server?.ssdp ?? false);
  bool get mdns => running && (_server?.mdns ?? false);
  String? get error => _server?.error;

  /// Which mDNS responder announces right now, or null.
  MdnsImplementation? get mdnsVia => running ? _server?.mdnsVia : null;

  BridgeBackground get _background => home.services.background;

  /// Whether the platform can keep the bridge running in the background.
  bool get backgroundSupported => _background.supported;

  /// Whether Android's own mDNS responder exists, so there is a choice.
  bool get systemMdnsAvailable => home.services.nsd.available;

  /// The "Announce on Wi-Fi" setting.
  bool get announce => _settings?.announce ?? true;

  /// The "Run in the background" setting.
  bool get background => _settings?.background ?? true;

  bool get stayAwakeWhileCharging => _settings?.stayAwakeWhileCharging ?? false;
  bool get mdnsEnabled => _settings?.mdnsEnabled ?? true;
  bool get ssdpEnabled => _settings?.ssdpEnabled ?? true;

  /// The mDNS responder the bridge uses: the chosen one, else the default.
  MdnsImplementation get mdnsImplementation =>
      (_settings?.mdnsWanted(systemAvailable: systemMdnsAvailable)) ?? MdnsImplementation.builtIn;

  /// Whether the running bridge is advertising itself right now.
  bool get announcing => ssdp || mdns;

  /// What Settings says about discovery while the bridge runs, else null.
  String? get announcement => running
      ? describe(
          name: MdnsResponder.label(settings),
          announce: announce,
          mdnsOn: mdnsEnabled,
          ssdpOn: ssdpEnabled,
          ssdp: ssdp,
          mdns: mdns,
          mdnsVia: mdnsVia,
          ssdpError: _server?.ssdpError,
          mdnsError: _server?.mdnsError,
          systemMdnsError: _server?.systemMdnsError,
        )
      : null;

  /// The discovery status line, naming only the mechanisms switched on.
  static String describe({
    required String name,
    required bool announce,
    bool mdnsOn = true,
    bool ssdpOn = true,
    required bool ssdp,
    required bool mdns,
    MdnsImplementation? mdnsVia,
    String? ssdpError,
    String? mdnsError,
    String? systemMdnsError,
  }) {
    const enter = 'Enter the address in the other app.';
    if (!announce) return 'Not announcing: Announce on Wi-Fi is off. $enter';
    if (!mdnsOn && !ssdpOn) return 'Not announcing: mDNS and SSDP are off. $enter';
    final working = [
      if (mdnsOn && mdns) mdnsVia == MdnsImplementation.system ? 'mDNS (Android)' : 'mDNS',
      if (ssdpOn && ssdp) 'SSDP',
    ];
    final broken = [
      if (mdnsOn && !mdns) ('mDNS', mdnsError ?? 'unknown error'),
      if (ssdpOn && !ssdp) ('SSDP', ssdpError ?? 'unknown error'),
    ];
    if (working.isEmpty) return 'Not announcing: ${[for (final (what, why) in broken) '$why ($what)'].join('; ')}';
    final only = broken.isEmpty
        ? ''
        : ' only; ${[for (final (what, why) in broken) '$what is unavailable: $why'].join('; ')}';
    final note = systemMdnsError == null ? '' : '; Android mDNS failed ($systemMdnsError), so the built-in one answers';
    return 'Announcing as $name on Wi-Fi via ${working.join(' and ')}$only$note';
  }

  /// Where clients reach the bridge, such as `http://192.168.1.20:1818`.
  String? get url => running && addresses.isNotEmpty ? 'http://${addresses.first}:$port' : null;

  /// The ports to try, in order.
  List<int> get ports => switch (_settings?.port) {
    final int p => [p],
    null => BridgeServer.defaultPorts,
  };

  List<PairedApp> get pairedApps => _settings == null ? const [] : List.unmodifiable(settings.users.values);

  /// How many paired apps were seen in the last [PairedApp.activeWindow].
  int get activeApps {
    final now = _clock();
    return pairedApps.where((a) => a.activeAt(now)).length;
  }

  /// Such as "2 apps paired, 1 active in the last 5 minutes"; null with none.
  String? get appsSummary {
    final paired = pairedApps.length;
    if (paired == 0) return null;
    final active = activeApps;
    return '$paired ${paired == 1 ? 'app' : 'apps'} paired, '
        '${active == 0 ? 'none' : '$active'} active in the last ${PairedApp.activeWindow.inMinutes} minutes';
  }

  /// When [app] was last seen, for Settings: "Active now", "Last seen 12
  /// min ago", "Last seen 3 h ago" or "Last seen 2026-10-20".
  static String lastSeen(PairedApp app, DateTime now) {
    final seen = app.lastUsed;
    if (seen == null) return 'Not seen yet';
    if (app.activeAt(now)) return 'Active now';
    final ago = now.difference(seen);
    if (ago < const Duration(hours: 1)) return 'Last seen ${ago.inMinutes} min ago';
    if (ago < const Duration(days: 1)) return 'Last seen ${ago.inHours} h ago';
    return 'Last seen ${LogEntry.date(seen.toLocal())}';
  }

  /// Whether [app] was seen in the last [PairedApp.activeWindow].
  bool isActive(PairedApp app) => app.activeAt(_clock());

  /// When [app] was last seen, as [lastSeen] words it now.
  String lastSeenOf(PairedApp app) => lastSeen(app, _clock());

  Duration get linkButtonRemaining => _api?.linkButtonRemaining ?? Duration.zero;

  Future<void>? _loading;

  /// Reads the settings and starts the server if it was left on. Calls made
  /// while loading share the first.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final store = home.services.emulatorStore;
    final stored = await store.load();
    final settings = stored ?? EmulatorSettings.create();
    _settings = settings;
    _api = BridgeApi(
      home,
      settings,
      clock: _clock,
      onChanged: _changed,
      onSeen: (_) => _refresh(),
      extensions: extensions,
    );
    if (stored == null) await store.save(settings);
    _notify();
    if (settings.enabled) await _start();
  }

  Future<void> _save() => home.services.emulatorStore.save(settings);

  /// The API changed the settings (pairing, a removal, a name, ids).
  void _changed() {
    unawaited(_save());
    _refresh();
  }

  /// Shows the latest counts in Settings and the notification.
  void _refresh() {
    unawaited(_syncBackground());
    _notify();
  }

  Future<void> setEnabled(bool on) async {
    if (!loaded || on == enabled) return;
    settings.enabled = on;
    _notify();
    await _save();
    if (!on) return _stop();
    await _start();
    if (background) await _askForNotifications();
  }

  /// Switches announcing on the Wi-Fi on or off; the HTTP API keeps running.
  Future<void> setAnnounce(bool on) => _setDiscovery(() => settings.announce = on, on != announce);

  /// Switches mDNS alone on or off, under Announce on Wi-Fi.
  Future<void> setMdnsEnabled(bool on) => _setDiscovery(() => settings.mdnsEnabled = on, on != mdnsEnabled);

  /// Switches SSDP alone on or off, under Announce on Wi-Fi.
  Future<void> setSsdpEnabled(bool on) => _setDiscovery(() => settings.ssdpEnabled = on, on != ssdpEnabled);

  /// Chooses Android's mDNS responder or the built-in one; a running bridge
  /// swaps them at once.
  Future<void> setMdnsImplementation(MdnsImplementation choice) =>
      _setDiscovery(() => settings.mdnsImplementation = choice, choice != mdnsImplementation);

  Future<void> _setDiscovery(void Function() apply, bool changed) async {
    if (!loaded || !changed) return;
    apply();
    _notify();
    await _save();
    await _server?.announcementChanged();
    _notify();
  }

  /// Switches the background service on or off for the running bridge.
  Future<void> setBackground(bool on) async {
    if (!loaded || on == background) return;
    settings.background = on;
    _notify();
    await _save();
    await _syncBackground();
    if (on && running) await _askForNotifications();
  }

  /// Holds a wake lock while the phone charges, through the service.
  Future<void> setStayAwakeWhileCharging(bool on) async {
    if (!loaded || on == stayAwakeWhileCharging) return;
    settings.stayAwakeWhileCharging = on;
    _notify();
    await _save();
    await _syncBackground();
  }

  /// Opens Android's battery optimisation settings; false where there are
  /// none.
  Future<bool> openBatterySettings() => _background.openBatterySettings();

  /// A denied permission hides the notification but the service still runs.
  Future<void> _askForNotifications() async {
    if (backgroundSupported) await _background.requestNotifications();
  }

  /// Runs, updates or stops the background service to match the bridge.
  Future<void> _syncBackground() async {
    if (!loaded || !backgroundSupported) return;
    if (running && background) {
      final wanted = (BridgeBackground.describe(url: url, active: activeApps), stayAwakeWhileCharging);
      if (wanted == _service) return;
      _service = wanted;
      await _background.run(text: wanted.$1, stayAwakeWhileCharging: wanted.$2);
    } else if (_service != null) {
      _service = null;
      await _background.stop();
    }
  }

  /// Once a minute while running: saves seen times left unsaved and lets
  /// apps that went quiet drop out of the active count.
  @visibleForTesting
  void tick() {
    if (api.takeUnsavedSeen()) unawaited(_save());
    _refresh();
  }

  Future<void> _start() async {
    if (_server != null) return;
    await home.services.multicast.acquire();
    final server = home.services.emulatorServer(api, ports, home.services.nsd);
    _server = server..addListener(_onServer);
    await server.start();
    _minute = Timer.periodic(const Duration(minutes: 1), (_) => tick());
    await _syncBackground();
    _notify();
  }

  void _onServer() => _refresh();

  Future<void> _stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    _minute?.cancel();
    server.removeListener(_onServer);
    await server.stop();
    await home.services.multicast.release();
    if (api.takeUnsavedSeen()) await _save();
    await _syncBackground();
    _notify();
  }

  /// Opens the 30 second pairing window, like the round button on a bridge,
  /// and ticks once a second so the countdown shows.
  void pressLinkButton() {
    if (!loaded) return;
    api.pressLinkButton();
    _countdown?.cancel();
    var ticks = 0;
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      ticks++;
      if (!api.linkButtonActive || ticks > BridgeApi.linkWindow.inSeconds) timer.cancel();
      _notify();
    });
    _notify();
  }

  /// Forgets a paired app, as `DELETE /config/whitelist/<key>` does.
  Future<void> revoke(String username) async {
    if (!loaded || !api.removeUser(username)) return;
    await _save();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _countdown?.cancel();
    _minute?.cancel();
    unawaited(_stop());
    super.dispose();
  }
}
