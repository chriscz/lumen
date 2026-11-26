// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/discovery_settings.dart';
import '../domain/errors.dart';
import '../domain/home.dart';
import '../color/color_math.dart';
import '../domain/light.dart';
import '../domain/power_on.dart';
import '../log/logger.dart';
import '../transport/ble/hue_ble_driver.dart';
import '../transport/bridge/hue_bridge_client.dart';
import '../transport/bridge/lan_bridge_discovery.dart';
import 'app_services.dart';

/// The app's single source of truth: the lights, bridges, rooms and profiles,
/// and every action on them. Changes show at once (optimistic) and roll back
/// if the light does not take them.
class HomeController extends ChangeNotifier {
  HomeController(this.services, {DateTime Function()? clock})
    : ble = HueBleDriver(services.central, log: services.log),
      _clock = clock ?? DateTime.now {
    _reports = ble.reports.listen(_onBleReport);
  }

  final DateTime Function() _clock;

  /// How long after a command a light's reported state is not trusted. Hue
  /// lights fade to a new level and report the levels in between; showing
  /// those would make a slider jump back.
  static const settleTime = Duration(seconds: 2);

  final Map<String, DateTime> _settleUntil = {};

  void _unsettle(String id) => _settleUntil[id] = _clock().add(settleTime);

  bool _settling(String id) {
    final until = _settleUntil[id];
    if (until == null) return false;
    if (_clock().isBefore(until) || (_pipes.values.any((p) => p.running != null && p.members.contains(id)))) {
      return true;
    }
    _settleUntil.remove(id);
    return false;
  }

  final AppServices services;
  final HueBleDriver ble;

  List<Light> _lights = [];

  /// Where each light is in [_lights], so a lookup by id is O(1).
  final Map<String, int> _index = {};
  List<BridgeAccount> _bridges = [];
  List<Room> _rooms = [];
  List<Profile> _profiles = [];
  bool _loaded = false;
  ThemeChoice _theme = ThemeChoice.dark;
  bool _debugLogging = false;
  DiscoverySettings _discovery = const DiscoverySettings();
  LightError? _bluetoothIssue;
  int _bluetoothIssueSeq = 0;
  bool _askedThisLaunch = false;

  Logger get log => services.log;

  final Map<String, LightState> _confirmed = {};
  final Map<String, _Pipe> _pipes = {};
  final Map<String, HueBridgeClient> _clients = {};
  final Map<String, List<BridgeGroup>> _bridgeGroups = {};
  final Map<String, int> _intent = {};
  final Map<String, Future<void>> _lightTail = {};
  final Map<String, Map<String, LightState>> _removedFromProfiles = {};
  Future<void>? _connecting;
  int _seq = 0;
  final Map<String, Set<String>> _bridgeLightIds = {};
  late final StreamSubscription<BleReport> _reports;
  final _errors = StreamController<LightError>.broadcast();
  final Set<String> _appSecurity = {};

  /// Lights whose optional features were read in this app session, on add
  /// or on the first connect. They are not read again until the next launch.
  final Set<String> _featuresRead = {};

  /// The light refused a write after bonding: it uses Hue's application-layer
  /// security, which the app does not implement.
  bool needsAppSecurity(String id) => _appSecurity.contains(id);

  List<Light> get lights => List.unmodifiable(_lights);
  List<BridgeAccount> get bridges => List.unmodifiable(_bridges);
  List<Room> get rooms => List.unmodifiable(_rooms);
  List<Profile> get profiles => List.unmodifiable(_profiles);
  bool get loaded => _loaded;
  ThemeChoice get themeChoice => _theme;
  bool get debugLogging => _debugLogging;

  /// Which ways of finding bridges are on.
  DiscoverySettings get discoverySettings => _discovery;

  /// Whether Android's mDNS browse can be chosen.
  bool get hasAndroidMdns => services.discovery.hasAndroidMdns;

  /// The mDNS implementation a search uses.
  MdnsImplementation get mdnsImplementation => _discovery.mdnsIn(androidAvailable: hasAndroidMdns);

  /// A missing permission or Bluetooth being off, for the UI to show until
  /// it is fixed. Null when Bluetooth is usable or not checked yet.
  LightError? get bluetoothIssue => _bluetoothIssue;

  /// Changes whenever the issue should be shown again: when it first
  /// appears, changes, or a user's retry fails.
  int get bluetoothIssueSeq => _bluetoothIssueSeq;

  /// Shows [e] as the Bluetooth issue when it is one: a missing permission
  /// or Bluetooth being off. False for any other failure, which the caller
  /// handles.
  bool _bluetoothFailed(LightError e, String why, {bool force = false}) {
    if (e is! BluetoothPermissionDenied && e is! BluetoothUnavailable) return false;
    _reportIssue(e, why, force: force);
    return true;
  }

  void _reportIssue(LightError? issue, String why, {bool force = false}) {
    final old = _bluetoothIssue;
    final same = issue?.runtimeType == old?.runtimeType && issue?.message == old?.message;
    log.debug(
      LogTag.controller,
      () => 'bluetooth issue ($why): ${issue?.runtimeType ?? 'none'}${same && !force ? ', unchanged' : ''}',
    );
    if (same && !force) return;
    _bluetoothIssue = issue;
    if (issue != null) _bluetoothIssueSeq++;
    notifyListeners();
  }

  /// Gets Bluetooth ready when the user opens Add light. Asks for the
  /// permission at most once per launch; after that only [retryBluetooth]
  /// asks, so a denied prompt never comes back on its own.
  Future<bool> prepareBluetooth() async {
    final request = !_askedThisLaunch;
    _askedThisLaunch = true;
    log.debug(LogTag.controller, () => 'prepare Bluetooth, ${request ? 'may ask' : 'already asked this launch'}');
    try {
      await ble.ensureReady(request: request);
    } on LightError catch (e) {
      if (!_bluetoothFailed(e, 'add light', force: true)) rethrow;
      return false;
    }
    _reportIssue(null, 'ready');
    return true;
  }

  /// The user's Retry: asks for the permission or to turn Bluetooth on
  /// again, and probes the bulbs once it works.
  Future<bool> retryBluetooth() async {
    _askedThisLaunch = true;
    log.debug(LogTag.controller, () => 'retry Bluetooth');
    try {
      await ble.ensureReady(request: true);
    } on LightError catch (e) {
      if (!_bluetoothFailed(e, 'retry', force: true)) _reportIssue(null, 'retry', force: true);
      return false;
    }
    _reportIssue(null, 'retry ok');
    await _probeBluetooth();
    return true;
  }

  /// What the Bluetooth stack says about itself, for Diagnostics.
  Future<Map<String, String>> bluetoothStatus() => services.central.status();

  /// How many of the Bluetooth lights have a connection open.
  int get connectedBulbCount {
    final connected = ble.connected;
    return _lights.where((l) => l.transport == Transport.ble && connected.contains(l.address)).length;
  }

  /// Errors to show the user, for example in a snack bar.
  Stream<LightError> get errors => _errors.stream;

  Light? light(String id) => switch (_index[id]) {
    final i? => _lights[i],
    null => null,
  };

  /// Rebuilds [_index] after lights left [_lights]. The first light with an
  /// id wins, as a search from the start would find it.
  void _reindex() {
    _index.clear();
    for (var i = 0; i < _lights.length; i++) {
      _index.putIfAbsent(_lights[i].id, () => i);
    }
  }

  Room? room(String id) => _rooms.where((r) => r.id == id).firstOrNull;

  Profile? profile(String id) => _profiles.where((p) => p.id == id).firstOrNull;

  Future<void> load() async {
    final snapshot = await services.store.load();
    _lights = [...snapshot.lights];
    _reindex();
    _bridges = [...snapshot.bridges];
    _rooms = [...snapshot.rooms];
    _profiles = snapshot.fresh ? starterProfiles() : [...snapshot.profiles];
    _theme = snapshot.theme;
    _debugLogging = snapshot.debugLogging;
    _discovery = snapshot.discovery;
    log
      ..debugEnabled = _debugLogging
      ..persist = _debugLogging;
    for (final b in _bridges) {
      log.addSecret(b.appKey);
    }
    log.info(
      LogTag.controller,
      'loaded ${_lights.length} lights, ${_bridges.length} bridges, debug logging ${_debugLogging ? 'on' : 'off'}',
    );
    for (final l in _lights) {
      _confirmed[l.id] = l.state;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void>? _pendingSave;

  /// Saves the home once at the end of the current microtask, however many
  /// changes ask for it, so a room command to many bulbs writes once.
  Future<void> _scheduleSave() => _pendingSave ??= Future.microtask(() {
    _pendingSave = null;
    return _write();
  });

  Future<void> _write() => services.store.save(
    HomeSnapshot(
      lights: _lights,
      bridges: _bridges,
      rooms: _rooms,
      profiles: _profiles,
      theme: _theme,
      debugLogging: _debugLogging,
      discovery: _discovery,
    ),
  );

  /// Adds or replaces [light] without telling listeners.
  void _set(Light light) {
    final i = _index[light.id];
    if (i == null) {
      _index[light.id] = _lights.length;
      _lights.add(light);
    } else {
      _lights[i] = light;
    }
  }

  void _put(Light light) {
    _set(light);
    notifyListeners();
  }

  // Bluetooth

  /// Hue bulbs nearby that are not added yet.
  Stream<DiscoveredBulb> scanBluetooth() => ble.discover().where((b) => light(bleId(b.deviceId)) == null);

  static String bleId(String deviceId) => 'ble:$deviceId';

  /// Hue bulbs this phone already bonded with (for example through the Hue
  /// app) that are not added yet. They need no pairing mode.
  Future<List<DiscoveredBulb>> knownBluetooth() async =>
      (await ble.knownBulbs()).where((b) => light(bleId(b.deviceId)) == null).toList();

  Future<Light> addBluetoothLight(DiscoveredBulb bulb) async {
    log.info(LogTag.controller, 'add Bluetooth bulb ${bulb.deviceId} "${bulb.name}"');
    final BleBulbInfo info;
    try {
      info = await ble.add(bulb.deviceId);
    } catch (e) {
      log.warning(LogTag.controller, 'adding ${bulb.deviceId} failed: $e');
      rethrow;
    }
    final added = Light(
      id: bleId(bulb.deviceId),
      name: info.name,
      transport: Transport.ble,
      address: bulb.deviceId,
      kind: info.kind,
      state: info.state,
      reachable: true,
      capabilities: info.capabilities,
      powerOnConfigurable: info.powerOn,
      minDimConfigurable: info.minDim,
    );
    _confirmed[added.id] = added.state;
    _featuresRead.add(added.id);
    _put(added);
    await _scheduleSave();
    return added;
  }

  void _onBleReport(BleReport report) {
    final id = bleId(report.deviceId);
    if (light(id) != null && _observed(id, report.state, reachable: true, merge: true)) notifyListeners();
  }

  /// Takes [state] as what light [id] reports, and as its confirmed state;
  /// with [merge], a partial report is layered over what is known. While
  /// the light settles after a command the levels it reports on the way are
  /// not trusted, so only [reachable] and [kind] are taken. Does not notify;
  /// returns whether the light changed.
  bool _observed(String id, LightState state, {required bool reachable, bool merge = false, LightKind? kind}) {
    final current = light(id)!;
    var next = current.state;
    if (!_settling(id)) {
      _confirmed[id] = merge ? (_confirmed[id] ?? LightState.unknown).mergeReport(state) : state;
      next = merge ? current.state.mergeReport(state) : state;
    }
    if (next == current.state && reachable == current.reachable && (kind ?? current.kind) == current.kind) return false;
    _set(current.copyWith(state: next, reachable: reachable, kind: kind));
    return true;
  }

  // Bridge

  HueBridgeClient _client(String host) => _clients[host] ??= services.bridgeClient(host);

  // Reconnecting

  final Set<String> _offline = {};
  final Map<String, Timer> _reconnect = {};
  final Map<String, int> _attempts = {};
  bool _foreground = true;

  /// Bridges that dropped off the network, which the app keeps trying to
  /// reach while it is in the foreground.
  Set<String> get offlineBridges => Set.unmodifiable(_offline);

  /// How many times the app tried to reach offline bridge [bridgeId] since
  /// it went offline or the app came back to the foreground.
  int reconnectAttempts(String bridgeId) => _attempts[bridgeId] ?? 0;

  /// The wait before retry [attempt]: 1, 2, 4, 8 and 16 seconds, then 30.
  static Duration reconnectDelay(int attempt) => Duration(seconds: min(30, 1 << min(attempt, 5)));

  /// Retries run only while the app is in the foreground. Coming back
  /// starts each offline bridge's backoff over.
  void setForeground(bool foreground) {
    _foreground = foreground;
    log.debug(LogTag.controller, () => 'app in the ${foreground ? 'foreground' : 'background'}');
    for (final t in _reconnect.values) {
      t.cancel();
    }
    _reconnect.clear();
    if (!foreground) return;
    for (final id in _offline) {
      _attempts[id] = 0;
      _scheduleReconnect(id);
    }
  }

  /// Runs [call] on [account]'s bridge and tracks whether the bridge is on
  /// the network: no answer marks it offline, any answer marks it back.
  Future<T> _onBridge<T>(BridgeAccount account, Future<T> Function() call) async {
    try {
      final result = await call();
      _bridgeAnswered(account.id);
      return result;
    } on BridgeOffline {
      _bridgeOffline(account.id);
      rethrow;
    } on LightError {
      _bridgeAnswered(account.id);
      rethrow;
    }
  }

  void _bridgeOffline(String id) {
    if (_offline.add(id)) {
      log.info(LogTag.controller, 'bridge $id is offline, reconnecting');
      _attempts[id] = 0;
      notifyListeners();
    }
    _scheduleReconnect(id);
  }

  void _bridgeAnswered(String id) {
    if (!_offline.remove(id)) return;
    log.info(LogTag.controller, 'bridge $id is back after ${_attempts[id]} attempts');
    _reconnect.remove(id)?.cancel();
    _attempts.remove(id);
    notifyListeners();
  }

  void _scheduleReconnect(String id) {
    if (!_foreground || _reconnect.containsKey(id)) return;
    final attempt = _attempts[id] ?? 0;
    _reconnect[id] = Timer(reconnectDelay(attempt), () {
      _reconnect.remove(id);
      _attempts[id] = attempt + 1;
      log.debug(LogTag.controller, () => 'reconnecting to bridge $id, attempt ${attempt + 1}');
      _refreshBridge(_bridges.firstWhere((b) => b.id == id), quiet: true);
    });
  }

  void _forgetOffline(String id) {
    _offline.remove(id);
    _attempts.remove(id);
    _reconnect.remove(id)?.cancel();
  }

  /// Looks for bridges on the local network with the methods that are on,
  /// trying the saved bridges first. Cancel the subscription to stop.
  Stream<DiscoveryEvent> discoverBridges() => services.discovery.discover(
    known: [for (final b in _bridges) b.host],
    stages: _discovery.enabled,
    mdns: mdnsImplementation,
  );

  Future<void> setDiscoveryStage(DiscoveryStage stage, bool on) async {
    _discovery = _discovery.withStage(stage, on);
    log.info(LogTag.controller, 'discovery by ${stage.name} ${on ? 'on' : 'off'}');
    notifyListeners();
    await _scheduleSave();
  }

  Future<void> setMdnsImplementation(MdnsImplementation implementation) async {
    _discovery = _discovery.withMdns(implementation);
    log.info(LogTag.controller, 'mDNS by ${implementation.name}');
    notifyListeners();
    await _scheduleSave();
  }

  /// Waits for the link button, stores the app key and imports the lights.
  Future<BridgeAccount> pairBridge(
    String host, {
    Duration interval = const Duration(seconds: 1),
    Duration timeout = const Duration(seconds: 30),
    bool Function()? cancelled,
  }) async {
    final client = _client(host);
    final config = await client.config();
    final key = await client.waitForLinkButton(interval: interval, timeout: timeout, cancelled: cancelled);
    // Lights removed before stay removed when the bridge is paired again.
    final kept = _bridges.where((b) => b.id == config.id).firstOrNull?.removedLights ?? const {};
    final account = BridgeAccount(id: config.id, name: config.name, host: host, appKey: key, removedLights: kept);
    log.addSecret(key);
    log.info(LogTag.controller, 'paired bridge ${config.id} at $host');
    _bridges = [..._bridges.where((b) => b.id != account.id), account];
    await _takeBridgeLights(account, await client.lights(key));
    await _importBridgeRooms(account);
    return account;
  }

  static String bridgeLightId(String bridgeId, String lightId) => 'bridge:$bridgeId:$lightId';

  /// Takes the lights a bridge listed: known ones take what it reports, new
  /// ones are added, and those the user removed stay out (and leave the
  /// removed list once the bridge no longer has them). Notifies and saves
  /// once, and only when one changed.
  Future<void> _takeBridgeLights(BridgeAccount account, List<BridgeLight> found) async {
    // Removed lights still belong to the bridge, so its all-lights group,
    // which would move them too, is not used while any is removed.
    _bridgeLightIds[account.id] = {for (final b in found) b.id};
    final removed = _removedLights(account.id);
    final stillThere = {
      for (final MapEntry(:key, :value) in removed.entries)
        if (_bridgeLightIds[account.id]!.contains(key)) key: value,
    };
    var changed = stillThere.length != removed.length;
    if (changed) _setRemovedLights(account.id, stillThere);
    for (final b in found) {
      if (stillThere.containsKey(b.id)) continue;
      final id = bridgeLightId(account.id, b.id);
      if (light(id) != null) {
        if (_observed(id, b.state, reachable: b.reachable, kind: b.kind)) changed = true;
      } else {
        changed = true;
        _confirmed[id] = b.state;
        _set(
          Light(
            id: id,
            name: b.name,
            transport: Transport.bridge,
            address: '${account.id}/${b.id}',
            kind: b.kind,
            state: b.state,
            reachable: b.reachable,
          ),
        );
      }
    }
    if (!changed) return;
    notifyListeners();
    await _scheduleSave();
  }

  /// Creates a room for every bridge room not already in the app. Saves
  /// even when the rooms cannot be read, since pairing changed the bridges.
  Future<void> _importBridgeRooms(BridgeAccount account) async {
    final List<BridgeGroup> groups;
    try {
      groups = await _client(account.host).groups(account.appKey);
    } on LightError {
      return _scheduleSave();
    }
    _bridgeGroups[account.id] = groups.where((g) => g.lightIds.length > 1).toList();
    for (final g in groups.where((g) => g.isRoom)) {
      final ids = [for (final l in g.lightIds) bridgeLightId(account.id, l)].where((id) => light(id) != null);
      final existing = _rooms.where((r) => r.name == g.name).firstOrNull;
      if (existing == null) {
        await createRoom(g.name, ids);
      } else {
        _assign(existing.id, ids.where((id) => light(id)!.roomId == null));
      }
    }
    await _scheduleSave();
  }

  /// Forgets a bridge and every light that came from it.
  Future<void> forgetBridge(String bridgeId) async {
    _bridges = _bridges.where((b) => b.id != bridgeId).toList();
    _forgetOffline(bridgeId);
    _bridgeGroups.remove(bridgeId);
    _bridgeLightIds.remove(bridgeId);
    _pipes.removeWhere((key, pipe) => key.startsWith('group:$bridgeId:') && pipe.running == null);
    final gone = _lights.where((l) => l.bridgeId == bridgeId).toSet();
    for (final l in gone) {
      _confirmed.remove(l.id);
    }
    _lights.removeWhere(gone.contains);
    _reindex();
    notifyListeners();
    await _scheduleSave();
  }

  Map<String, String> _removedLights(String bridgeId) =>
      _bridges.where((b) => b.id == bridgeId).firstOrNull?.removedLights ?? const {};

  void _setRemovedLights(String bridgeId, Map<String, String> removed) {
    _bridges = [
      for (final b in _bridges) b.id == bridgeId ? b.copyWith(removedLights: removed) : b,
    ];
  }

  /// Takes a removed bridge light back into the app.
  Future<void> addBridgeLightBack(String bridgeId, String lightId) =>
      _addBack(bridgeId, {..._removedLights(bridgeId)}..remove(lightId));

  /// Takes every removed light of a bridge back into the app.
  Future<void> addAllBridgeLightsBack(String bridgeId) => _addBack(bridgeId, const {});

  Future<void> _addBack(String bridgeId, Map<String, String> removed) async {
    _setRemovedLights(bridgeId, removed);
    notifyListeners();
    await _scheduleSave();
    await _refreshBridge(_bridges.firstWhere((b) => b.id == bridgeId), quiet: true);
  }

  /// Reads the current state of every bridge light. When [quiet], as in
  /// background polling, an unreachable bridge marks its lights unreachable
  /// instead of raising an error.
  Future<void> refresh({bool quiet = false}) =>
      Future.wait([for (final account in _bridges) _refreshBridge(account, quiet: quiet)]);

  /// Reads a bridge's lights and groups in parallel, then takes the lights
  /// and after them the groups.
  Future<void> _refreshBridge(BridgeAccount account, {required bool quiet}) async {
    final client = _client(account.host);
    final lights = _onBridge(account, () => client.lights(account.appKey));
    final groups = _groupsOrNull(client, account.appKey);
    try {
      await _takeBridgeLights(account, await lights);
    } on LightError catch (e) {
      for (final l in _lightsOf(account)) {
        _set(l.copyWith(reachable: false));
      }
      notifyListeners();
      if (!quiet) _errors.add(e);
      return;
    }
    // Groups that cannot be read keep the ones known; per-light calls still
    // work without them.
    if (await groups case final read?) _bridgeGroups[account.id] = read.where((g) => g.lightIds.length > 1).toList();
  }

  static Future<List<BridgeGroup>?> _groupsOrNull(HueBridgeClient client, String key) async {
    try {
      return await client.groups(key);
    } on LightError {
      return null;
    }
  }

  // Control

  // These act on one light as the user asked; a light in a cluster detaches.

  Future<void> setPower(String id, bool on) => _single(id, LightCommand(on: on));

  Future<void> setBrightness(String id, int brightness) =>
      _single(id, LightCommand(on: true, brightness: HueRange.brightness(brightness)));

  Future<void> setColor(String id, LightColor color) => _single(id, LightCommand(on: true, color: color));

  Future<void> _single(String id, LightCommand command) {
    _clusters.detach(id);
    return send(id, command);
  }

  void _updateRoom(Room room) => _setRooms([for (final r in _rooms) r.id == room.id ? room : r]);

  void _setRooms(List<Room> rooms) {
    _rooms = rooms;
    notifyListeners();
    unawaited(_scheduleSave());
  }

  late final _clusters = _Clusters(this);

  bool isDetached(String lightId) => _clusters.isDetached(lightId);

  Set<String> detachedIn(String roomId) => _clusters.detachedIn(roomId);

  /// Puts a detached light back into its cluster, with the cluster's settings.
  Future<void> rejoin(String roomId, String lightId) => _rejoin(roomId, {lightId});

  /// Puts every detached light of a cluster back, with the cluster's settings.
  Future<void> resetCluster(String roomId) => _rejoin(roomId, detachedIn(roomId));

  Future<void> _rejoin(String roomId, Set<String> ids) async {
    final state = _clusters.rejoin(roomId, ids);
    if (state == null) return;
    final sends = <Future<void>>[];
    for (final id in ids) {
      final l = light(id);
      if (l == null) continue;
      final (adapted, _) = ColorMath.adapt(state, l.kind);
      sends.add(send(id, (adapted.on ?? false) ? adapted.toCommand() : const LightCommand(on: false)));
    }
    await Future.wait(sends);
  }

  /// Shows [command] at once and sends it. Commands sent while one is in
  /// flight merge into one, so a dragged slider never queues up.
  Future<void> send(String id, LightCommand command) {
    if (light(id) == null || command.isEmpty) return Future.value();
    log.debug(LogTag.controller, () => 'command $id: $command');
    return _enqueue(id, [id], command, (c) => _deliver(id, c));
  }

  /// Sends one command to many lights at once. Bridge lights that make up a
  /// whole bridge group get one group action; the rest are sent one by one,
  /// in parallel.
  Future<void> sendAll(Iterable<String> ids, LightCommand command) {
    if (command.isEmpty) return Future.value();
    final remaining = ids.where((id) => light(id) != null).toSet();
    final sends = <Future<void>>[];
    for (final account in _bridges) {
      final mine = remaining.where((id) => light(id)!.bridgeId == account.id).toSet();
      if (mine.length < 2) continue;
      for (final group in _groupsOf(account)) {
        final members = [for (final l in group.lightIds) bridgeLightId(account.id, l)];
        if (members.length < 2 || !members.every(mine.contains)) continue;
        mine.removeAll(members);
        remaining.removeAll(members);
        final client = _client(account.host);
        sends.add(
          _enqueue(
            'group:${account.id}:${group.id}',
            members,
            command,
            (c) => _onBridge(account, () => client.groupAction(account.appKey, group.id, c)),
          ),
        );
      }
    }
    sends.addAll([for (final id in remaining) send(id, command)]);
    return Future.wait(sends);
  }

  /// Sends each light its own command. Lights given the same command go
  /// out together through [sendAll], so they can share a group action.
  Future<void> sendEach(Map<String, LightCommand> commands) {
    final byCommand = <LightCommand, List<String>>{};
    for (final MapEntry(key: id, value: command) in commands.entries) {
      byCommand.putIfAbsent(command, () => []).add(id);
    }
    return Future.wait([for (final MapEntry(key: command, value: ids) in byCommand.entries) sendAll(ids, command)]);
  }

  /// The bridge's groups that the app may use: group 0 when the app holds
  /// every light of the bridge, then its rooms and zones, largest first.
  /// A group with a light the app does not hold is never used.
  List<BridgeGroup> _groupsOf(BridgeAccount account) {
    final known = _bridgeLightIds[account.id] ?? const <String>{};
    final held = {for (final l in _lightsOf(account)) l.bridgeLightId!};
    final all = known.isNotEmpty && held.containsAll(known)
        ? [BridgeGroup(id: '0', name: 'All', lightIds: known.toList(), type: 'LightGroup')]
        : <BridgeGroup>[];
    final groups =
        (_bridgeGroups[account.id] ?? const <BridgeGroup>[]).where((g) => g.lightIds.every(held.contains)).toList()
          ..sort((a, b) => b.lightIds.length.compareTo(a.lightIds.length));
    return [...all, ...groups];
  }

  Future<void> _enqueue(
    String key,
    List<String> members,
    LightCommand command,
    Future<void> Function(LightCommand) deliver,
  ) {
    final seq = ++_seq;
    for (final id in members) {
      _intent[id] = seq;
      _unsettle(id);
      final l = light(id);
      if (l != null) _set(l.copyWith(state: l.state.apply(command)));
    }
    notifyListeners();
    final pipe = _pipes.putIfAbsent(key, _Pipe.new);
    // The newest route wins: a re-paired bridge may have a new address or key.
    pipe
      ..members = members
      ..deliver = deliver;
    if (pipe.pending == null) {
      pipe.pendingSeq = seq;
    } else {
      log.debug(LogTag.controller, () => 'coalesced a command for $key into the pending one');
    }
    pipe.pending = pipe.pending?.merge(command) ?? command;
    pipe.latestSeq = seq;
    final done = Completer<void>();
    pipe.waiters.add(done);
    pipe.running ??= _drain(pipe);
    return done.future;
  }

  /// Sends a pipe's commands one at a time. Deliveries that touch the same
  /// light go out in the order the user asked for them: a pipe first lets
  /// overlapping pipes with older queued commands take theirs, then waits
  /// for earlier deliveries to those lights to finish.
  Future<void> _drain(_Pipe pipe) async {
    try {
      while (pipe.pending != null) {
        pipe.waiting = true;
        while (true) {
          final older = [
            for (final o in _pipes.values)
              if (!identical(o, pipe) &&
                  !o.waiting &&
                  o.pending != null &&
                  o.pendingSeq < pipe.pendingSeq &&
                  o.members.any(pipe.members.contains))
                o.taken.future,
          ];
          if (older.isEmpty) break;
          await Future.any(older);
        }
        pipe.waiting = false;

        final command = pipe.pending!;
        final seq = pipe.latestSeq;
        final members = pipe.members;
        final deliver = pipe.deliver;
        final waiters = [...pipe.waiters];
        pipe
          ..pending = null
          ..waiters.clear();
        pipe.taken.complete();
        pipe.taken = Completer<void>();

        final before = [for (final id in members) ?_lightTail[id]];
        final finished = Completer<void>();
        for (final id in members) {
          _lightTail[id] = finished.future;
        }
        try {
          await Future.wait(before);
          await deliver(command);
          _appSecurity.removeAll(members);
          for (final id in members) {
            _unsettle(id);
            _confirmed[id] = (_confirmed[id] ?? LightState.unknown).apply(command);
            final l = light(id);
            if (l != null && !l.reachable) _put(l.copyWith(reachable: true));
          }
        } catch (e) {
          log.warning(LogTag.controller, 'delivery of $command to $members failed, rolled back: $e');
          // Roll back only lights nobody has asked anything newer of.
          for (final id in members) {
            final l = light(id);
            if (l != null && (_intent[id] ?? 0) <= seq) {
              _put(l.copyWith(state: _confirmed[id] ?? l.state, reachable: false));
            }
          }
          if (e is NeedsAppSecurity) {
            _markAppSecurity(members, e);
          } else {
            _errors.add(e is LightError ? e : LightUnreachable('Unexpected error: $e'));
          }
        } finally {
          finished.complete();
          for (final id in members) {
            if (identical(_lightTail[id], finished.future)) _lightTail.remove(id);
          }
          for (final w in waiters) {
            w.complete();
          }
        }
      }
    } finally {
      pipe.running = null;
    }
    await _scheduleSave();
  }

  Future<void> _deliver(String id, LightCommand command) async {
    final l = light(id);
    if (l == null) return;
    switch (l.transport) {
      case Transport.ble:
        await ble.send(l.address, _withinRange(l, command));
      case Transport.bridge:
        final (account, lightId) = _bridgeOf(l);
        await _onBridge(account, () => _client(account.host).setState(account.appKey, lightId, command));
    }
  }

  /// The codec only clamps to what the wire can carry, so keep colour
  /// temperatures inside what the light can show.
  static LightCommand _withinRange(Light l, LightCommand c) {
    final (lo, hi) = l.miredsRange;
    return switch (c.color) {
      WhiteColor(:final mireds) when mireds < lo || mireds > hi => c.withColor(WhiteColor(mireds.clamp(lo, hi))),
      _ => c,
    };
  }

  /// Probes every light after launch or resume: refreshes the bridges and,
  /// at the same time, reads Bluetooth bulbs. Lights that do not answer are
  /// unreachable. Calls made while a probe runs share it.
  Future<void> connectAll() => _connecting ??= Future.wait([refresh(), _probeBluetooth()]).whenComplete(() {
    _connecting = null;
  });

  Future<void> _probeBluetooth() async {
    final bulbs = _lights.where((l) => l.transport == Transport.ble).toList();
    if (bulbs.isEmpty) return;
    try {
      await ble.ensureReady();
    } on LightError catch (e) {
      for (final l in bulbs) {
        final current = light(l.id);
        if (current != null) _put(current.copyWith(reachable: false));
      }
      // Shown once, with its own Retry; never a prompt without a user action.
      if (!_bluetoothFailed(e, 'probe')) _errors.add(e);
      return;
    }
    _reportIssue(null, 'probe ok');
    var featuresChanged = false;
    await Future.wait([
      for (final l in bulbs)
        ble
            .readState(l.address)
            .then(
              (state) async {
                _confirmed[l.id] = state;
                final current = light(l.id);
                if (current != null) _put(current.copyWith(state: state, reachable: true));
                if (await _refreshCapabilities(l.id)) featuresChanged = true;
              },
              onError: (Object _) {
                final current = light(l.id);
                if (current != null) _put(current.copyWith(reachable: false));
              },
            ),
    ]);
    if (featuresChanged) await _scheduleSave();
  }

  /// Reads a connected bulb's capabilities again, so a light added before
  /// they were read, or one with new firmware, gets the right controls.
  /// Once per light and app session; true when they changed, so the caller
  /// saves once for all lights.
  Future<bool> _refreshCapabilities(String id) async {
    final l = light(id);
    if (l == null || !_featuresRead.add(id)) return false;
    try {
      final features = await ble.readFeatures(l.address);
      final current = light(id);
      if (current == null) return false;
      // An unknown light type keeps the kind the light has.
      if ((features.capabilities ?? current.capabilities) == current.capabilities &&
          (features.capabilities?.kind ?? current.kind) == current.kind &&
          features.powerOn == current.powerOnConfigurable &&
          features.minDim == current.minDimConfigurable) {
        log.debug(LogTag.controller, () => 'capabilities of $id unchanged');
        return false;
      }
      _put(
        current.copyWith(
          capabilities: features.capabilities,
          kind: features.capabilities?.kind,
          powerOnConfigurable: features.powerOn,
          minDimConfigurable: features.minDim,
        ),
      );
      return true;
    } on LightError catch (e) {
      _featuresRead.remove(id);
      log.debug(LogTag.controller, () => 'capabilities of $id not refreshed: $e');
      return false;
    }
  }

  /// What a Bluetooth light does when its power returns, read from the bulb.
  /// Null when it cannot say.
  Future<PowerOnBehavior?> powerOnBehavior(String id) async {
    final l = _bleLight(id);
    if (l == null) return null;
    final behavior = await ble.readPowerOn(l.address);
    log.debug(LogTag.controller, () => 'power-on behaviour of $id: $behavior');
    return behavior;
  }

  /// Sets what a Bluetooth light does when its power returns. Always on
  /// uses the light's current brightness and colour.
  Future<void> setPowerOnMode(String id, PowerOnMode mode) async {
    final l = _bleLight(id);
    if (l == null) return;
    log.info(LogTag.controller, 'power-on behaviour of $id: ${mode.name}');
    await ble.writePowerOn(l.address, PowerOnBehavior.forMode(mode, l.kind, l.state));
  }

  /// The lowest level a Bluetooth light dims to, from 0 to 1: read from the
  /// bulb where it allows that, else the level Lumen last wrote. Null when
  /// neither is known.
  Future<double?> minDim(String id) async {
    final l = _bleLight(id);
    if (l == null) return null;
    return await ble.readMinDim(l.address) ?? light(id)?.minDimLevel;
  }

  /// Sets the lowest level a Bluetooth light dims to, from 0 to 1.
  Future<void> setMinDim(String id, double level) async {
    final l = _bleLight(id);
    if (l == null) return;
    log.info(LogTag.controller, 'minimum dim level of $id: ${(level * 100).round()}%');
    await ble.writeMinDim(l.address, level);
    final current = light(id);
    if (current == null) return;
    _put(current.copyWith(minDimLevel: level));
    await _scheduleSave();
  }

  /// Opens a Bluetooth bulb for bonding for about five minutes, so another
  /// phone or app can pair with it.
  Future<void> makeDiscoverable(String id) async {
    final l = _bleLight(id);
    if (l == null) return;
    log.info(LogTag.controller, 'make discoverable $id');
    try {
      await ble.makeDiscoverable(l.address);
    } on LightError catch (e) {
      log.warning(LogTag.controller, 'make discoverable $id failed: $e');
      rethrow;
    }
  }

  /// Blinks a light so the user can tell which one it is.
  Future<void> identify(String id, {Duration step = const Duration(milliseconds: 450)}) async {
    final l = light(id);
    if (l == null) return;
    try {
      switch (l.transport) {
        case Transport.ble:
          try {
            await ble.identify(l.address);
            return;
          } on CharacteristicMissing catch (e) {
            // Only a light without the identify characteristic blinks its
            // power instead. Any other failure is reported as it is.
            log.debug(LogTag.controller, () => 'no identify command on $id, blinking the power instead: $e');
          }
          await _blinkPower(id, l.address, l.isOn, step);
        case Transport.bridge:
          final (account, lightId) = _bridgeOf(l);
          await _client(account.host).alert(account.appKey, lightId);
      }
    } on NeedsAppSecurity catch (e) {
      _markAppSecurity([id], e);
    } on LightError catch (e) {
      _errors.add(e);
    }
  }

  /// Toggles the power four times, ending as it was. If a step fails, puts
  /// the power back before the error is reported, and when even that fails
  /// shows the power the light was left with.
  Future<void> _blinkPower(String id, String address, bool on, Duration step) async {
    var written = on;
    try {
      for (final value in [!on, on, !on, on]) {
        await ble.send(address, LightCommand(on: value));
        written = value;
        if (step > Duration.zero) await Future<void>.delayed(step);
      }
    } finally {
      if (written != on) {
        try {
          await ble.send(address, LightCommand(on: on));
        } on LightError catch (e) {
          log.warning(LogTag.controller, 'restoring the power of $id after blinking failed: $e');
          final current = light(id);
          if (current != null) {
            final left = LightCommand(on: written);
            _confirmed[id] = (_confirmed[id] ?? current.state).apply(left);
            _put(current.copyWith(state: current.state.apply(left)));
          }
        }
      }
    }
  }

  /// [ids] refused a write after bonding: shows that on them and reports it.
  void _markAppSecurity(Iterable<String> ids, NeedsAppSecurity e) {
    _appSecurity.addAll(ids);
    notifyListeners();
    _errors.add(e);
  }

  (BridgeAccount, String) _bridgeOf(Light l) {
    final account = _bridges.where((b) => b.id == l.bridgeId).firstOrNull;
    if (account == null) throw const BridgeUnauthorized();
    return (account, l.bridgeLightId!);
  }

  /// The lights that came from [account]'s bridge.
  List<Light> _lightsOf(BridgeAccount account) => _lights.where((l) => l.bridgeId == account.id).toList();

  /// The Bluetooth light [id], or null when there is none.
  Light? _bleLight(String id) {
    final l = light(id);
    return l != null && l.transport == Transport.ble ? l : null;
  }

  // Effects and fades

  /// Starts [effect] on a bulb, or ends the running one with [HueEffect.none]
  /// by setting the current colour again.
  Future<void> setEffect(String id, HueEffect effect, {int speed = 128}) {
    final l = light(id);
    if (l == null) return Future.value();
    _clusters.detach(id);
    final colour = l.state.color ?? const WhiteColor(HueRange.defaultMireds);
    return send(
      id,
      LightCommand(
        on: true,
        brightness: l.state.brightness ?? 254,
        color: colour,
        effect: effect,
        effectSpeed: effect == HueEffect.none ? null : speed,
      ),
    );
  }

  /// Shows [gradient] on a gradient light, in one write with the power.
  Future<void> setGradient(String id, LightGradient gradient) =>
      _single(id, LightCommand(on: true, gradient: gradient));

  /// The longest transition both protocols can express: 0xFFFF tenths of a second.
  static const maxTransition = Duration(milliseconds: 0xFFFF * 100);

  /// Switches [ids] off slowly. The bulbs (or the bridge) run the fade, so
  /// the app does not need to stay open.
  Future<void> fadeOff(Iterable<String> ids, Duration over) =>
      sendAll(ids, LightCommand(on: false, transition: over > maxTransition ? maxTransition : over));

  /// Turns debug logging on or off, and keeps the choice. A debug log is
  /// kept between runs; otherwise only its last lines are.
  Future<void> setDebugLogging(bool on) async {
    _debugLogging = on;
    log
      ..debugEnabled = on
      ..persist = on;
    log.info(LogTag.controller, 'debug logging ${on ? 'on' : 'off'}');
    notifyListeners();
    await _scheduleSave();
  }

  Future<void> setThemeChoice(ThemeChoice choice) async {
    _theme = choice;
    notifyListeners();
    await _scheduleSave();
  }

  // Rooms

  int _nextId = 0;

  String _newId(String prefix) => '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_nextId++}';

  List<Light> lightsIn(String roomId) => _lights.where((l) => l.roomId == roomId).toList();

  List<Light> get unassigned => _lights.where((l) => l.roomId == null || room(l.roomId!) == null).toList();

  bool roomIsOn(String roomId) => lightsIn(roomId).any((l) => l.isOn);

  Future<Room> createRoom(String name, Iterable<String> lightIds, {bool linked = false}) async {
    final room = Room(id: _newId('room'), name: name.trim(), linked: linked);
    _rooms = [..._rooms, room];
    _assign(room.id, lightIds);
    await _scheduleSave();
    return room;
  }

  Future<void> updateRoom(Room room, Iterable<String> lightIds) {
    _updateRoom(room);
    for (final l in lightsIn(room.id)) {
      if (!lightIds.contains(l.id)) _set(l.copyWith(roomId: () => null));
    }
    _assign(room.id, lightIds);
    return _scheduleSave();
  }

  /// Puts [lightIds] in [roomId], with one notification for all of them.
  void _assign(String roomId, Iterable<String> lightIds) {
    for (final id in lightIds) {
      final l = light(id);
      if (l != null) _set(l.copyWith(roomId: () => roomId));
    }
    notifyListeners();
  }

  /// Links a group's lights into one light, or unlinks them back into a
  /// plain group.
  Future<void> setLinked(String roomId, bool linked) {
    if (room(roomId) case final r?) _updateRoom(r.copyWith(linked: linked));
    return _scheduleSave();
  }

  List<Room> get clusters => _rooms.where((r) => r.linked).toList();

  /// A linked group as the one light it acts as: the first member's state,
  /// on when any member is on, reachable when any member is.
  Light clusterLight(Room room) {
    final members = lightsIn(room.id);
    final lit = members.where((l) => l.isOn).firstOrNull ?? members.firstOrNull;
    final own = room.clusterState;
    return Light(
      id: 'cluster:${room.id}',
      name: room.name,
      transport: members.firstOrNull?.transport ?? Transport.ble,
      address: room.id,
      kind: members.any((l) => l.kind.hasColor)
          ? LightKind.color
          : (members.any((l) => l.kind.hasTemperature) ? LightKind.ambiance : LightKind.white),
      state: own.on != null ? (lit?.state ?? LightState.unknown).mergeReport(own) : (lit?.state ?? LightState.unknown),
      reachable: members.any((l) => l.reachable),
    );
  }

  Future<void> deleteRoom(String roomId) async {
    _rooms = _rooms.where((r) => r.id != roomId).toList();
    for (final l in lightsIn(roomId)) {
      _set(l.copyWith(roomId: () => null));
    }
    notifyListeners();
    await _scheduleSave();
  }

  Future<void> setRoomPower(String roomId, bool on) => _toGroup(roomId, LightCommand(on: on));

  Future<void> setRoomBrightness(String roomId, int brightness) =>
      _toGroup(roomId, LightCommand(on: true, brightness: HueRange.brightness(brightness)));

  Future<void> _toGroup(String roomId, LightCommand command) => sendAll(_clusters.command(roomId, command), command);

  /// Sets every light of a group to [color], each as close as its kind
  /// allows: white ambiance bulbs get the nearest white, white-only bulbs
  /// only switch on.
  Future<void> setRoomColor(String roomId, LightColor color) => sendEach({
    for (final id in _clusters.command(roomId, LightCommand(on: true, color: color)))
      id: LightCommand(on: true, color: ColorMath.adapt(LightState(on: true, color: color), light(id)!.kind).$1.color),
  });

  /// Switches every light off, and every cluster with them, so a cluster
  /// shows off and keeps its look for the next time it is switched on.
  Future<void> allOff() {
    const off = LightCommand(on: false);
    if (_rooms.any((r) => r.linked)) {
      _setRooms([for (final r in _rooms) r.linked ? r.copyWith(clusterState: r.clusterState.apply(off)) : r]);
    }
    return sendAll(_lights.map((l) => l.id), off);
  }

  // Profiles

  List<Profile> get favoriteProfiles => _profiles.where((p) => p.favorite).toList();

  static List<Profile> starterProfiles() => const [
    Profile(
      id: 'starter-relax',
      name: 'Relax',
      states: {Profile.presetKey: LightState(on: true, brightness: 144, color: WhiteColor(447))},
      favorite: true,
    ),
    Profile(
      id: 'starter-read',
      name: 'Read',
      states: {Profile.presetKey: LightState(on: true, brightness: 254, color: WhiteColor(346))},
    ),
    Profile(
      id: 'starter-concentrate',
      name: 'Concentrate',
      states: {Profile.presetKey: LightState(on: true, brightness: 254, color: WhiteColor(233))},
      favorite: true,
    ),
    Profile(
      id: 'starter-energise',
      name: 'Energise',
      states: {Profile.presetKey: LightState(on: true, brightness: 254, color: WhiteColor(156))},
    ),
    Profile(
      id: 'starter-nightlight',
      name: 'Nightlight',
      states: {Profile.presetKey: LightState(on: true, brightness: 1, color: XyColor(0.5612, 0.4042))},
      favorite: true,
    ),
  ];

  /// Captures the current state of [lightIds] as a scene.
  Future<Profile> saveScene(String name, Iterable<String> lightIds) async {
    final profile = Profile(
      id: _newId('profile'),
      name: name.trim(),
      states: {
        for (final id in lightIds)
          if (light(id) case final l?)
            id: LightState(on: l.state.on ?? false, brightness: l.state.brightness, color: l.state.color),
      },
    );
    await _setProfiles([..._profiles, profile]);
    return profile;
  }

  Future<Profile> savePreset(String name, LightState state) async {
    final profile = Profile(id: _newId('profile'), name: name.trim(), states: {Profile.presetKey: state});
    await _setProfiles([..._profiles, profile]);
    return profile;
  }

  /// Applies [profileId]: a scene to its own lights, a preset to [to] (or
  /// every light). Returns how many lights could only show an approximation.
  Future<int> applyProfile(String profileId, {Iterable<String>? to}) async {
    final profile = this.profile(profileId);
    if (profile == null) return 0;
    final transition = Duration(milliseconds: profile.transitionMs);
    final targets = profile.isPreset
        ? {for (final id in to ?? _lights.map((l) => l.id)) id: profile.preset!}
        : {
            for (final e in profile.states.entries)
              if (to == null || to.contains(e.key)) e.key: e.value,
          };
    _clusters.follow(targets);
    var approximated = 0;
    final sends = <Future<void>>[];
    for (final MapEntry(key: id, value: state) in targets.entries) {
      final l = light(id);
      if (l == null) continue;
      final (adapted, changed) = ColorMath.adapt(state, l.kind);
      if (changed) approximated++;
      sends.add(send(id, _profileCommand(adapted, transition)));
    }
    await Future.wait(sends);
    return approximated;
  }

  static LightCommand _profileCommand(LightState state, Duration transition) =>
      (state.on ?? true) ? state.toCommand(transition: transition) : LightCommand(on: false, transition: transition);

  /// The profiles that make sense for one light: every preset, and the
  /// scenes that include it.
  List<Profile> profilesFor(String lightId) => [
    for (final p in _profiles)
      if (p.isPreset || p.states.containsKey(lightId)) p,
  ];

  /// The profiles for a linked cluster: presets, and scenes with any of its lights.
  List<Profile> profilesForCluster(String roomId) {
    final members = lightsIn(roomId).map((l) => l.id).toSet();
    return [
      for (final p in _profiles)
        if (p.isPreset || p.states.keys.any(members.contains)) p,
    ];
  }

  /// Applies a profile to a linked cluster as one light: the look becomes
  /// the cluster's own and reaches every light still in the cluster. A
  /// scene gives the cluster the look of its first light that is in it.
  Future<void> applyProfileToCluster(String profileId, String roomId) async {
    final profile = this.profile(profileId);
    final room = this.room(roomId);
    if (profile == null || room == null) return;
    final members = lightsIn(roomId);
    final look =
        profile.preset ??
        [for (final l in members) ?profile.states[l.id]].firstOrNull ??
        profile.states.values.firstOrNull;
    if (look == null) return;
    final targets = _clusters.adopt(room, look);
    final transition = Duration(milliseconds: profile.transitionMs);
    await Future.wait([
      for (final l in members)
        if (targets.contains(l.id)) send(l.id, _profileCommand(ColorMath.adapt(look, l.kind).$1, transition)),
    ]);
  }

  Future<void> _setProfiles(List<Profile> profiles) {
    _profiles = profiles;
    notifyListeners();
    return _scheduleSave();
  }

  Future<void> updateProfile(Profile profile) =>
      _setProfiles([for (final p in _profiles) p.id == profile.id ? profile : p]);

  Future<void> toggleProfileFavorite(String profileId) async {
    final p = profile(profileId);
    if (p != null) await updateProfile(p.copyWith(favorite: !p.favorite));
  }

  Future<void> deleteProfile(String profileId) => _setProfiles(_profiles.where((p) => p.id != profileId).toList());

  Future<void> restoreProfile(Profile profile) =>
      _setProfiles([..._profiles.where((p) => p.id != profile.id), profile]);

  // Management

  Future<void> toggleFavorite(String id) async {
    final l = light(id);
    if (l == null) return;
    _put(l.copyWith(favorite: !l.favorite));
    await _scheduleSave();
  }

  Future<void> rename(String id, String name) async {
    final l = light(id);
    if (l == null || name.trim().isEmpty) return;
    _put(l.copyWith(name: name.trim()));
    await _scheduleSave();
    if (l.transport == Transport.ble) {
      // The bulb keeps its own name too, so other apps see it. The app's
      // name stands even when the bulb cannot be reached.
      try {
        await ble.rename(l.address, name.trim());
      } on NeedsAppSecurity catch (e) {
        _markAppSecurity([id], e);
      } on LightError catch (e) {
        log.warning(LogTag.controller, 'renaming $id on the bulb failed: $e');
      }
    }
  }

  Future<void> remove(String id) async {
    final l = light(id);
    if (l == null) return;
    _lights.removeWhere((x) => x.id == id);
    _reindex();
    _confirmed.remove(id);
    _featuresRead.remove(id);
    _removedFromProfiles[id] = {for (final p in _profiles) p.id: ?p.states[id]};
    if (l.bridgeId case final bridgeId?) {
      _setRemovedLights(bridgeId, {..._removedLights(bridgeId), l.bridgeLightId!: l.name});
    }
    _profiles = [
      for (final p in _profiles) p.copyWith(states: {...p.states}..remove(id)),
    ];
    notifyListeners();
    if (l.transport == Transport.ble) await ble.disconnect(l.address);
    await _scheduleSave();
  }

  /// Puts a removed light back, for undo.
  Future<void> restore(Light l) async {
    if (l.bridgeId case final bridgeId?) {
      _setRemovedLights(bridgeId, {..._removedLights(bridgeId)}..remove(l.bridgeLightId));
    }
    final scenes = _removedFromProfiles.remove(l.id) ?? const {};
    _profiles = [
      for (final p in _profiles)
        if (scenes[p.id] case final state?) p.copyWith(states: {...p.states, l.id: state}) else p,
    ];
    _confirmed[l.id] = l.state;
    _put(l);
    await _scheduleSave();
  }

  @override
  void dispose() {
    for (final t in _reconnect.values) {
      t.cancel();
    }
    _reports.cancel();
    _errors.close();
    super.dispose();
  }
}

class _Pipe {
  List<String> members = const [];

  /// Set by every command queued on the pipe, before it drains.
  late Future<void> Function(LightCommand) deliver;
  LightCommand? pending;

  /// Sequence number of the oldest and newest command merged into [pending].
  int pendingSeq = 0;
  int latestSeq = 0;
  bool waiting = false;
  Completer<void> taken = Completer<void>();
  Future<void>? running;
  final List<Completer<void>> waiters = [];
}

/// The bookkeeping of linked groups (clusters): the setting a cluster
/// keeps as its own, and the members that left it after a change of their
/// own. Each command entry point makes one call here.
class _Clusters {
  _Clusters(this._home);

  final HomeController _home;

  /// The linked group [lightId] is in, if any.
  Room? of(String lightId) {
    final roomId = _home.light(lightId)?.roomId;
    final room = roomId == null ? null : _home.room(roomId);
    return room != null && room.linked ? room : null;
  }

  bool isDetached(String lightId) => of(lightId)?.detached.contains(lightId) ?? false;

  Set<String> detachedIn(String roomId) =>
      _home.room(roomId)?.detached.where((id) => _home.light(id)?.roomId == roomId).toSet() ?? const {};

  /// A light changed on its own leaves its cluster.
  void detach(String lightId) {
    final room = of(lightId);
    if (room == null || room.detached.contains(lightId)) return;
    _home._updateRoom(room.copyWith(detached: {...room.detached, lightId}));
  }

  /// Starts a group command: a linked group records [command] as its own
  /// setting. Returns the lights the command goes to.
  List<String> command(String roomId, LightCommand command) {
    final room = _home.room(roomId);
    if (room != null && room.linked) _home._updateRoom(room.copyWith(clusterState: room.clusterState.apply(command)));
    return _targets(roomId, room);
  }

  /// Gives [room] [look] as its own setting. Returns the lights it goes to.
  List<String> adopt(Room room, LightState look) {
    _home._updateRoom(room.copyWith(clusterState: look));
    return _targets(room.id, room);
  }

  /// Every member, except members a cluster has lost to a direct change.
  List<String> _targets(String roomId, Room? room) => [
    for (final l in _home.lightsIn(roomId))
      if (room == null || !room.linked || !room.detached.contains(l.id)) l.id,
  ];

  /// Puts [ids] back into the group [roomId]. Returns the look they take,
  /// or null when there is nothing to rejoin.
  LightState? rejoin(String roomId, Set<String> ids) {
    final room = _home.room(roomId);
    if (room == null || ids.isEmpty) return null;
    _home._updateRoom(room.copyWith(detached: room.detached.difference(ids)));
    return _home.clusterLight(room).state;
  }

  /// Keeps linked clusters honest when a profile reaches their lights: a
  /// cluster whose every light gets the same look takes that look as its
  /// own; lights that get something else leave the cluster, as when the
  /// user changes one light on its own.
  /// Every cluster is updated in one batch.
  void follow(Map<String, LightState> targets) {
    var changed = false;
    Room take(Room room) {
      final next = room.linked ? _followed(room, targets) : null;
      if (next == null) return room;
      changed = true;
      return next;
    }

    final rooms = [for (final room in _home._rooms) take(room)];
    if (changed) _home._setRooms(rooms);
  }

  /// [room] after [targets] reach it, or null when they miss it.
  Room? _followed(Room room, Map<String, LightState> targets) {
    final members = _home.lightsIn(room.id).map((l) => l.id).toList();
    final hit = members.where(targets.containsKey).toList();
    if (hit.isEmpty) return null;
    final looks = hit.map((id) => targets[id]!).toSet();
    return hit.length == members.length && looks.length == 1
        ? room.copyWith(clusterState: looks.single, detached: const {})
        : room.copyWith(detached: {...room.detached, ...hit});
  }
}
