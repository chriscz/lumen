// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/capabilities.dart';
import '../../domain/errors.dart';
import '../../domain/light.dart';
import '../../domain/power_on.dart';
import '../../log/logger.dart';
import '../../util/hex.dart';
import 'ble_central.dart';
import 'hue_ble_codec.dart';

class DiscoveredBulb {
  const DiscoveredBulb({required this.deviceId, required this.name, this.rssi, this.openForBonding});

  final String deviceId;
  final String name;
  final int? rssi;

  /// The advertisement says the bulb accepts a new bond now.
  final bool? openForBonding;
}

class BleBulbInfo {
  const BleBulbInfo({
    required this.deviceId,
    required this.name,
    required this.kind,
    required this.state,
    this.capabilities,
    this.powerOn = false,
    this.minDim = false,
  });

  /// The bulb has the minimum dim level characteristic.
  final bool minDim;

  /// The bulb has the startup characteristic, so its power-on behaviour can
  /// be set.
  final bool powerOn;

  final String deviceId;
  final String name;
  final LightKind kind;
  final LightState state;

  /// From the capabilities characteristic; null when the bulb has none.
  final LightCapabilities? capabilities;
}

class BleReport {
  const BleReport(this.deviceId, this.state);

  final String deviceId;
  final LightState state;
}

/// Talks to Hue Bluetooth bulbs through a [BleCentral]. Connects on demand
/// and keeps at most [maxConnections] links open, closing the least recently
/// used one first, because phones hold only a few at a time (seven on most
/// Android controllers).
class HueBleDriver {
  HueBleDriver(
    this.central, {
    this.maxConnections = 7,
    Logger? log,
    this.bondTimeout = const Duration(seconds: 6),
    this.bondPoll = const Duration(milliseconds: 500),
    this.pairingTimeout = const Duration(seconds: 30),
    this.proximitySettle = const Duration(milliseconds: 200),
  }) : log = log ?? Logger.memory();

  /// The whole pairing attempt gives up after this, as the Hue app does.
  final Duration pairingTimeout;

  /// Pause after the proximity handshake before the bond starts.
  final Duration proximitySettle;

  /// The MTU the Hue app asks for.
  static const mtu = 247;

  final BleCentral central;
  final int maxConnections;
  final Logger log;

  /// How long to wait for a bond after an encrypted read started one.
  final Duration bondTimeout;
  final Duration bondPoll;

  static String _short(String uuid) => uuid.length > 13 ? uuid.substring(0, 13) : uuid;

  final List<String> _lru = [];
  final Map<String, StreamSubscription<bool>> _connectionSubs = {};
  final Map<String, StreamSubscription<Uint8List>> _notifySubs = {};
  final _reports = StreamController<BleReport>.broadcast();

  /// State changes the bulbs report, whoever made them.
  Stream<BleReport> get reports => _reports.stream;

  Set<String> get connected => _lru.toSet();

  Stream<DiscoveredBulb> discover() => central
      .scan(services: [HueGatt.advertisedService])
      .map((a) {
        log.debug(
          LogTag.ble,
          () =>
              'advert ${a.deviceId} "${a.name}" rssi ${a.rssi} services ${a.services} '
              'open for bonding ${a.openForBonding}',
        );
        return DiscoveredBulb(
          deviceId: a.deviceId,
          name: a.name.isEmpty ? 'Hue bulb' : a.name,
          rssi: a.rssi,
          openForBonding: a.openForBonding,
        );
      })
      .handleError((Object e) {
        log.warning(LogTag.ble, 'scan failed: $e');
        throw _translate(e);
      }, test: (e) => e is BleOperationException);

  /// Hue bulbs already bonded with this phone (for example by the Hue app)
  /// or connected by another app. These need no pairing mode, and often do
  /// not advertise.
  Future<List<DiscoveredBulb>> knownBulbs() async {
    try {
      final known = await central.knownDevices();
      log.debug(LogTag.ble, () => 'known devices: ${[for (final a in known) '${a.deviceId} "${a.name}"']}');
      return [for (final a in known) DiscoveredBulb(deviceId: a.deviceId, name: a.name.isEmpty ? 'Hue bulb' : a.name)];
    } on BleOperationException catch (e) {
      log.warning(LogTag.ble, 'listing known devices failed: $e');
      return const [];
    }
  }

  Future<void> ensureReady({bool request = false}) async {
    try {
      await central.ensureReady(request: request);
    } on BleOperationException catch (e) {
      log.debug(LogTag.ble, () => 'not ready (request $request): $e');
      throw _translate(e);
    }
  }

  /// Connects, bonds and reads the bulb's name, kind and state.
  Future<BleBulbInfo> add(String deviceId) => _on(deviceId, () async {
    log.info(LogTag.ble, 'adding $deviceId');
    try {
      await _ensureConnected(deviceId);
    } on BleOperationException catch (e) {
      log.warning(LogTag.ble, 'connect to $deviceId failed while adding: $e');
      // It advertised a moment ago, so a bulb that does not answer is held
      // by another phone or the Hue app.
      if (e.kind == BleFailure.timeout) throw const BulbBusy();
      rethrow;
    }
    try {
      if (await _bond(deviceId).timeout(pairingTimeout)) {
        // A subscription made on the unbonded link was refused: make it again.
        log.debug(LogTag.ble, () => 'bonded $deviceId, subscribing to notifications again');
        _subscribeControl(deviceId);
      }
    } on TimeoutException {
      log.warning(LogTag.ble, 'pairing $deviceId timed out after ${pairingTimeout.inSeconds} s');
      throw const PairingTimedOut();
    }
    if (await _securityKeySet(deviceId)) {
      log.warning(LogTag.ble, 'bulb $deviceId has an application-layer security key; Lumen cannot drive it');
      throw const NeedsAppSecurity();
    }
    final name = await _readString(deviceId, HueGatt.configService, HueGatt.name);
    final model = await _readString(deviceId, HueGatt.deviceInfoService, HueGatt.model);
    final capabilities = await _readCapabilities(deviceId);
    final kind = _kindFor(capabilities, model);
    log.info(LogTag.ble, 'added $deviceId ("$name", model $model, $kind)');
    return BleBulbInfo(
      deviceId: deviceId,
      name: name ?? 'Hue bulb',
      kind: kind,
      state: await _readState(deviceId),
      capabilities: capabilities,
      powerOn: await _readPowerOn(deviceId) != null,
      minDim: await _has(deviceId, HueGatt.lightService, HueGatt.minDim),
    );
  });

  /// The bulb's minimum dim level from 0 to 1, or null when it does not
  /// have the characteristic or, as the spec has it, does not let it be read.
  Future<double?> readMinDim(String deviceId) => _connected(
    deviceId,
    () => _readOptional(
      deviceId,
      HueGatt.lightService,
      HueGatt.minDim,
      HueBleCodec.decodeMinDim,
      fallback: null,
      what: 'no minimum dim level on $deviceId',
    ),
  );

  /// Sets the lowest level the bulb dims to, from 0 to 1.
  Future<void> writeMinDim(String deviceId, double level) => _connected(
    deviceId,
    () => _writeProtected(deviceId, HueGatt.lightService, HueGatt.minDim, HueBleCodec.encodeMinDim(level)),
  );

  /// What the bulb does when its power returns, or null when it does not
  /// have the startup characteristic.
  Future<PowerOnBehavior?> readPowerOn(String deviceId) => _connected(deviceId, () => _readPowerOn(deviceId));

  Future<PowerOnBehavior?> _readPowerOn(String id) => _readOptional<PowerOnBehavior?>(
    id,
    HueGatt.lightService,
    HueGatt.startup,
    HueBleCodec.decodePowerOn,
    fallback: null,
    what: 'no startup characteristic on $id',
    found: (behavior) => 'power-on behaviour $id: $behavior',
  );

  /// Sets what the bulb does when its power returns.
  Future<void> writePowerOn(String deviceId, PowerOnBehavior behavior) => _connected(
    deviceId,
    () => _writeProtected(deviceId, HueGatt.lightService, HueGatt.startup, HueBleCodec.encodePowerOn(behavior)),
  );

  /// Whether the bulb reports a provisioned application-layer security key.
  /// False when it does not have the characteristic or the read fails.
  Future<bool> _securityKeySet(String id) => _readOptional(
    id,
    HueGatt.configService,
    HueGatt.securityKey,
    HueBleCodec.securityKeySet,
    fallback: false,
    what: 'no security key characteristic on $id',
    found: (set) => 'security key on $id: ${set ? 'set' : 'not set'}',
  );

  /// Runs a read or write of a characteristic that application-layer
  /// security protects. A refusal on a bonded bulb means it wants a secure
  /// session (see docs/protocol.md), which Lumen does not open.
  Future<T> _protected<T>(String id, Future<T> Function() op) async {
    try {
      return await op();
    } on BleOperationException catch (e) {
      if (!_refusal(e)) rethrow;
      if (await _isPaired(id) != true) rethrow;
      log.warning(LogTag.ble, 'bonded bulb $id refused protected access ($e): it needs application-layer security');
      throw const NeedsAppSecurity();
    }
  }

  Future<void> _writeProtected(String id, String service, String characteristic, Uint8List value) =>
      _protected(id, () => _write(id, service, characteristic, value));

  static bool _refusal(BleOperationException e) =>
      e.kind == BleFailure.unauthenticated ||
      (e.kind == BleFailure.other && RegExp('auth|encrypt', caseSensitive: false).hasMatch('${e.code} ${e.detail}'));

  /// The kind from the capabilities' light type, or from the model number
  /// when the bulb has no capabilities or names a type the spec does not.
  LightKind _kindFor(LightCapabilities? capabilities, String? model) {
    final fromType = capabilities?.kind;
    if (fromType != null) return fromType;
    if (capabilities != null) {
      log.debug(LogTag.ble, () => 'unknown light type ${capabilities.lightType}, using model $model');
    }
    return _kindForModel(model);
  }

  /// The optional features of a connected bulb in one go: its capabilities
  /// (null when it has none), and whether it has the startup and minimum
  /// dim characteristics.
  Future<({LightCapabilities? capabilities, bool powerOn, bool minDim})> readFeatures(String deviceId) => _connected(
    deviceId,
    () async => (
      capabilities: await _readCapabilities(deviceId),
      powerOn: await _readPowerOn(deviceId) != null,
      // Write-only on the wire (docs/protocol.md): only its presence tells.
      minDim: await _has(deviceId, HueGatt.lightService, HueGatt.minDim),
    ),
  );

  Future<LightCapabilities?> _readCapabilities(String id) => _readOptional<LightCapabilities?>(
    id,
    HueGatt.lightService,
    HueGatt.capabilities,
    HueBleCodec.decodeCapabilities,
    fallback: null,
    what: 'no capabilities on $id, falling back to the model number',
    found: (caps) => 'capabilities $id: $caps',
  );

  /// Bonds with the bulb unless this phone already holds a bond. When the
  /// platform's pair call fails, reads an encrypted characteristic, which
  /// makes Android start the bond itself, and waits for it. True when it
  /// bonded now, false when the phone already held a bond.
  Future<bool> _bond(String id) async {
    final paired = await _isPaired(id);
    log.debug(LogTag.ble, () => 'isPaired $id: $paired');
    if (paired == true) return false;

    final flags = await _proximity(id);
    if (flags != null) {
      if (!flags.openForBonding && !flags.bondedToPhone) {
        log.warning(LogTag.ble, 'bulb $id is not open for bonding: $flags');
        if (flags.windowExpired) throw const BondWindowExpired();
        throw NotInPairingMode(onBridge: flags.onBridge);
      }
      if (proximitySettle > Duration.zero) await Future<void>.delayed(proximitySettle);
      await _requestMtu(id);
      final (bonded, _) = await _bondByEncryptedRead(id);
      if (bonded) return true;
      log.debug(LogTag.ble, () => 'encrypted read did not bond $id, falling back to pair');
    }

    BleOperationException pairError;
    final pairing = Stopwatch()..start();
    try {
      log.debug(LogTag.ble, () => 'pair $id');
      await central.pair(id);
      log.debug(LogTag.ble, () => 'pair $id ok in ${pairing.elapsedMilliseconds} ms');
      return true;
    } on BleOperationException catch (e) {
      log.debug(LogTag.ble, () => 'pair $id failed after ${pairing.elapsedMilliseconds} ms: $e');
      if (_fatal(e)) rethrow;
      pairError = e;
    }

    final (bonded, readError) = await _bondByEncryptedRead(id);
    if (bonded) return true;
    log.debug(LogTag.ble, () => 'not bonded $id after ${bondTimeout.inMilliseconds} ms');
    log.warning(LogTag.ble, 'bulb $id did not bond. pair: $pairError; read: ${readError ?? 'ok'}');
    if (pairError.kind == BleFailure.unauthenticated || readError?.kind == BleFailure.unauthenticated) {
      throw BleOperationException(BleFailure.unauthenticated, pairError.detail, pairError.code);
    }
    throw readError ?? pairError;
  }

  /// Proximity pairing handshake: writes 0x01 without response to 2001 and
  /// reads the flag byte back. Null when the bulb has no such
  /// characteristic, as on older firmware.
  Future<ProximityFlags?> _proximity(String id) async {
    if (!await _has(id, HueGatt.configService, HueGatt.proximity)) {
      log.debug(LogTag.ble, () => 'no proximity handshake on $id: it has no proximity characteristic');
      return null;
    }
    return _optional(
      () async {
        await _write(id, HueGatt.configService, HueGatt.proximity, Uint8List.fromList([0x01]), withoutResponse: true);
        final v = await _read(id, HueGatt.configService, HueGatt.proximity);
        if (v.isEmpty) return null;
        final flags = ProximityFlags(v.first);
        log.debug(LogTag.ble, () => 'proximity flags $flags');
        return flags;
      },
      fallback: null,
      what: 'no proximity handshake on $id',
    );
  }

  Future<void> _requestMtu(String id) async {
    try {
      final granted = await central.requestMtu(id, mtu);
      log.debug(LogTag.ble, () => 'mtu $id: asked $mtu, got $granted');
    } on BleOperationException catch (e) {
      log.debug(LogTag.ble, () => 'mtu request $id failed: $e');
    }
  }

  /// Reads the encrypted control characteristic, which makes Android bond
  /// with a bulb that is open for bonding, and waits for the bond.
  Future<(bool, BleOperationException?)> _bondByEncryptedRead(String id) async {
    log.debug(LogTag.ble, () => 'reading control to start bonding $id');
    BleOperationException? readError;
    try {
      final v = await central.read(id, HueGatt.lightService, HueGatt.control);
      log.debug(LogTag.ble, () => 'read $id ${_short(HueGatt.control)} -> ${hex(v)}');
    } on BleOperationException catch (e) {
      log.debug(LogTag.ble, () => 'encrypted read $id failed: $e');
      if (_fatal(e)) rethrow;
      readError = e;
    }

    // Counted in polls, not by a clock, so fake time in tests drives it too.
    final polls = bondPoll.inMicroseconds <= 0 ? 1 : (bondTimeout.inMicroseconds / bondPoll.inMicroseconds).ceil();
    for (var poll = 0; ; poll++) {
      final now = await _isPaired(id);
      if (now == true || (now == null && readError == null)) {
        log.debug(LogTag.ble, () => 'bonded $id after ${(bondPoll * poll).inMilliseconds} ms');
        return (true, null);
      }
      if (poll >= polls) break;
      await Future<void>.delayed(bondPoll);
    }
    return (false, readError);
  }

  /// Opens a connected bulb for bonding for about five minutes, so another
  /// phone or app can pair with it. Repeat it to keep it open.
  Future<void> makeDiscoverable(String deviceId) => _on(deviceId, () async {
    log.info(LogTag.ble, 'make discoverable $deviceId');
    await _ensureConnected(deviceId);
    try {
      await _write(deviceId, HueGatt.configService, HueGatt.makeDiscoverable, Uint8List.fromList([0x01]));
    } on BleOperationException catch (e) {
      if (_fatal(e) || e.kind == BleFailure.timeout) rethrow;
      log.warning(LogTag.ble, 'bulb $deviceId refused make discoverable: $e');
      throw DiscoverableRefused('${e.code ?? e.kind.name}: ${e.detail}');
    }
  });

  /// Whether the connected bulb offers an optional characteristic, from the
  /// services discovered on connect. An optional probe reads only what is
  /// there, and still treats a notFound answer as absent.
  Future<bool> _has(String id, String service, String characteristic) async {
    try {
      final has = await central.hasCharacteristic(id, service, characteristic);
      if (!has) log.debug(LogTag.ble, () => 'no ${_short(characteristic)} on $id');
      return has;
    } on BleOperationException catch (e) {
      log.debug(LogTag.ble, () => 'hasCharacteristic $id ${_short(characteristic)} failed: $e');
      return true;
    }
  }

  /// Reads an optional characteristic and decodes it. [fallback] when the
  /// bulb does not have it or the read fails other than fatally; [what]
  /// starts the log line for that failure, [found] the one for the value.
  Future<T> _readOptional<T>(
    String id,
    String service,
    String characteristic,
    T Function(Uint8List bytes) decode, {
    required T fallback,
    required String what,
    String Function(T value)? found,
  }) async {
    if (!await _has(id, service, characteristic)) return fallback;
    return _optional(
      () async {
        final value = decode(await _read(id, service, characteristic));
        if (found != null) log.debug(LogTag.ble, () => found(value));
        return value;
      },
      fallback: fallback,
      what: what,
    );
  }

  /// Runs [op] on an optional characteristic: a failure that is not fatal
  /// is logged after [what] and gives [fallback].
  Future<T> _optional<T>(Future<T> Function() op, {required T fallback, required String what}) async {
    try {
      return await op();
    } on BleOperationException catch (e) {
      if (_fatal(e)) rethrow;
      log.debug(LogTag.ble, () => '$what: $e');
      return fallback;
    }
  }

  /// Whether this phone holds a bond with [id]; null when the platform
  /// cannot tell or the query fails.
  Future<bool?> _isPaired(String id) async {
    try {
      return await central.isPaired(id);
    } on BleOperationException catch (e) {
      log.debug(LogTag.ble, () => 'isPaired $id failed: $e');
      return null;
    }
  }

  static bool _fatal(BleOperationException e) => switch (e.kind) {
    BleFailure.permissionDenied || BleFailure.unavailable || BleFailure.unreachable || BleFailure.notConnected => true,
    _ => false,
  };

  Future<Uint8List> _read(String id, String service, String characteristic) async {
    try {
      final v = await central.read(id, service, characteristic);
      log.debug(LogTag.ble, () => 'read $id ${_short(characteristic)} (service ${_short(service)}) -> ${hex(v)}');
      return v;
    } on BleOperationException catch (e) {
      log.debug(LogTag.ble, () => 'read $id ${_short(characteristic)} (service ${_short(service)}) failed: $e');
      rethrow;
    }
  }

  Future<void> _write(
    String id,
    String service,
    String characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    log.debug(
      LogTag.ble,
      () =>
          'write $id ${_short(characteristic)} (service ${_short(service)})'
          '${withoutResponse ? ' without response' : ''}: ${hex(value)}',
    );
    try {
      await central.write(id, service, characteristic, value, withoutResponse: withoutResponse);
    } on BleOperationException catch (e) {
      log.debug(LogTag.ble, () => 'write $id ${_short(characteristic)} failed: $e');
      rethrow;
    }
  }

  Future<LightState> readState(String deviceId) => _connected(deviceId, () => _readState(deviceId));

  /// Writes [command] as one combined control write, reconnecting once if
  /// the link had dropped or the phone's GATT table was stale.
  Future<void> send(String deviceId, LightCommand command) => _on(deviceId, () async {
    if (command.isEmpty) return;
    final bytes = HueBleCodec.encodeControl(command);
    await _ensureConnected(deviceId);
    await _protected(deviceId, () async {
      try {
        await _write(deviceId, HueGatt.lightService, HueGatt.control, bytes);
      } on BleOperationException catch (e) {
        switch (e.kind) {
          case BleFailure.notConnected:
            log.debug(LogTag.ble, () => 'link to $deviceId was stale, reconnecting');
            _forgetLink(deviceId);
          case BleFailure.notFound:
            // The control characteristic every Hue bulb has is missing: the
            // phone's GATT table is stale. A new link discovers it again.
            log.debug(LogTag.ble, () => 'GATT table of $deviceId is stale, reconnecting to discover it again');
            await _disconnect(deviceId);
          default:
            rethrow;
        }
        await _ensureConnected(deviceId);
        try {
          await _write(deviceId, HueGatt.lightService, HueGatt.control, bytes);
        } on BleOperationException catch (e) {
          if (e.kind != BleFailure.notFound) rethrow;
          log.warning(LogTag.ble, 'bulb $deviceId still offers no control characteristic after reconnecting: $e');
          throw CharacteristicMissing('control characteristic: ${e.code ?? e.kind.name} ${e.detail}'.trim());
        }
      }
    });
  });

  /// Makes the light blink with the identify command (docs/protocol.md):
  /// one byte 0x01, written with response to 0006.
  /// Fails with [CharacteristicMissing] when the bulb does not have it.
  Future<void> identify(String deviceId) => _connected(deviceId, () async {
    if (!await _has(deviceId, HueGatt.lightService, HueGatt.identify)) {
      throw CharacteristicMissing('no identify characteristic');
    }
    await _writeProtected(deviceId, HueGatt.lightService, HueGatt.identify, Uint8List.fromList([0x01]));
  });

  Future<void> rename(String deviceId, String name) => _connected(
    deviceId,
    () => _writeProtected(deviceId, HueGatt.configService, HueGatt.name, HueBleCodec.encodeName(name)),
  );

  Future<void> disconnect(String deviceId) => _on(deviceId, () => _disconnect(deviceId));

  Future<void> _disconnect(String deviceId) async {
    _forgetLink(deviceId);
    await central.disconnect(deviceId);
  }

  static LightKind _kindForModel(String? model) => switch (model?.toUpperCase()) {
    final m? when m.startsWith('LOM') => LightKind.onOff,
    final m? when m.startsWith('LW') => LightKind.white,
    final m? when m.startsWith('LT') => LightKind.ambiance,
    _ => LightKind.color,
  };

  /// Reads the state from the combined control characteristic, as the Hue
  /// app does, or from the single-value characteristics when it cannot.
  Future<LightState> _readState(String id) async {
    try {
      return HueBleCodec.decodeControl(await _protected(id, () => _read(id, HueGatt.lightService, HueGatt.control)));
    } on BleOperationException catch (e) {
      if (_fatal(e)) rethrow;
      log.debug(LogTag.ble, () => 'combined state read on $id failed, reading single values: $e');
    }
    return _readSingleValues(id);
  }

  Future<LightState> _readSingleValues(String id) async {
    Future<Uint8List> read(String c) => _read(id, HueGatt.lightService, c);
    final power = HueBleCodec.decodePower(await read(HueGatt.power));
    final brightness = HueBleCodec.decodeBrightness(await read(HueGatt.brightness));
    LightColor? color;
    try {
      color = HueBleCodec.decodeXy(await read(HueGatt.xy));
    } on BleOperationException {
      color = null;
    }
    if (color == null) {
      try {
        final m = HueBleCodec.decodeMireds(await read(HueGatt.temperature));
        if (m != null) color = WhiteColor(m);
      } on BleOperationException {
        color = null;
      }
    }
    return LightState(on: power, brightness: brightness, color: color);
  }

  Future<String?> _readString(String id, String service, String characteristic) async {
    try {
      final bytes = await _read(id, service, characteristic);
      final s = utf8.decode(bytes, allowMalformed: true).replaceAll('\u0000', '').trim();
      return s.isEmpty ? null : s;
    } on BleOperationException catch (e) {
      if (e.kind == BleFailure.notConnected || e.kind == BleFailure.unreachable) rethrow;
      return null;
    }
  }

  /// Connects [id] if it is not connected. When the pool is full of busy
  /// links this waits, outside the connection lock, until a link goes idle
  /// or drops, then tries again. Holding the lock while waiting would
  /// deadlock: an op whose link dropped must be able to reconnect.
  Future<void> _ensureConnected(String id) async {
    while (true) {
      if (_lru.contains(id)) {
        _lru
          ..remove(id)
          ..add(id);
        return;
      }
      final seen = _freed;
      if (await _serial(() => _connect(id))) return;
      log.debug(LogTag.ble, () => 'every link is busy, $id waits for one to free');
      if (_freed == seen) await _freedSignal.future;
    }
  }

  /// Connects [id] under the connection lock, first closing the least
  /// recently used idle link if the pool is full. A link that is busy is
  /// never closed: if all are busy this returns false, and the caller waits
  /// for one to free. A phone that allows fewer links than
  /// [maxConnections] is treated the same way.
  Future<bool> _connect(String id) async {
    if (_lru.contains(id)) return true;
    while (_lru.length >= maxConnections) {
      if (!await _closeLeastRecentlyUsed()) return false;
    }
    while (true) {
      final timing = Stopwatch()..start();
      try {
        log.debug(LogTag.ble, () => 'connect $id (${_lru.length} links open)');
        await central.connect(id);
        log.debug(LogTag.ble, () => 'connected $id in ${timing.elapsedMilliseconds} ms');
        break;
      } on BleOperationException catch (e) {
        log.debug(LogTag.ble, () => 'connect $id failed after ${timing.elapsedMilliseconds} ms: $e');
        if (e.kind != BleFailure.connectionLimit || _lru.isEmpty) rethrow;
        if (!await _closeLeastRecentlyUsed()) return false;
      }
    }
    _lru.add(id);
    _connectionSubs[id] = central.connectionChanges(id).listen((up) {
      log.debug(LogTag.ble, () => 'connection $id ${up ? 'up' : 'down'}');
      if (!up) _forgetLink(id);
    });
    _subscribeControl(id);
    return true;
  }

  /// Subscribes to the control characteristic's notifications, replacing
  /// any earlier subscription. A bulb refuses this on a link that is not
  /// bonded yet, so it is done again after bonding.
  void _subscribeControl(String id) {
    unawaited(_notifySubs.remove(id)?.cancel());
    _notifySubs[id] = central.notifications(id, HueGatt.lightService, HueGatt.control).listen((bytes) {
      log.debug(LogTag.ble, () => 'notify $id ${_short(HueGatt.control)}: ${hex(bytes)}');
      _reports.add(BleReport(id, HueBleCodec.decodeControl(bytes)));
    }, onError: (Object e) => log.debug(LogTag.ble, () => 'notifications $id failed: $e'));
  }

  /// Closes the least recently used idle link. False when every link is
  /// busy.
  Future<bool> _closeLeastRecentlyUsed() async {
    final victim = _lru.where((d) => (_busy[d] ?? 0) == 0).firstOrNull;
    if (victim == null) return false;
    await _disconnect(victim);
    return true;
  }

  /// Counts the times a link went idle or a slot in the pool freed, and
  /// wakes whoever waits for that.
  int _freed = 0;
  Completer<void> _freedSignal = Completer<void>();

  void _signalFreed() {
    _freed++;
    final signal = _freedSignal;
    _freedSignal = Completer<void>();
    signal.complete();
  }

  void _forgetLink(String id) {
    if (!_lru.remove(id)) return;
    _signalFreed();
    unawaited(_connectionSubs.remove(id)?.cancel());
    unawaited(_notifySubs.remove(id)?.cancel());
  }

  /// Runs GATT work for one bulb at a time, in order, while work for other
  /// bulbs runs in parallel. A bulb counts as busy while its work runs, so
  /// the pool never closes its link underneath it.
  Future<T> _on<T>(String deviceId, Future<T> Function() body) => _perDevice.run(deviceId, () async {
    _busy[deviceId] = (_busy[deviceId] ?? 0) + 1;
    try {
      return await body();
    } on BleOperationException catch (e) {
      throw _translate(e);
    } finally {
      _busy[deviceId] = _busy[deviceId]! - 1;
      _signalFreed();
    }
  });

  /// Runs [body] under the bulb's lock once its link is up.
  Future<T> _connected<T>(String deviceId, Future<T> Function() body) => _on(deviceId, () async {
    await _ensureConnected(deviceId);
    return body();
  });

  /// Runs [body] after every earlier connection change has finished.
  Future<T> _serial<T>(Future<T> Function() body) => _connects.run(null, body);

  final _perDevice = _Queue();
  final _connects = _Queue();
  final Map<String, int> _busy = {};

  static LightError _translate(Object e) => switch (e) {
    LightError() => e,
    BleOperationException(kind: BleFailure.notFound, :final code, :final detail) => CharacteristicMissing(
      '${code ?? 'notFound'}: $detail',
    ),
    BleOperationException(kind: BleFailure.unauthenticated) => const NotInPairingMode(),
    BleOperationException(kind: BleFailure.unavailable) => const BluetoothUnavailable(),
    BleOperationException(kind: BleFailure.permissionDenied, :final code) => BluetoothPermissionDenied(
      permanent: code == 'permanentlyDenied',
    ),
    BleOperationException(
      kind: BleFailure.unreachable || BleFailure.notConnected || BleFailure.connectionLimit || BleFailure.timeout,
    ) =>
      const LightUnreachable(),
    BleOperationException(:final kind, :final code, :final detail) => BluetoothError(code ?? kind.name, detail),
    _ => const LightUnreachable(),
  };
}

/// Runs work in order per key: each body starts once the one queued before
/// it under the same key has finished, whether it succeeded or failed.
class _Queue {
  final Map<Object?, Future<void>> _tails = {};

  Future<T> run<T>(Object? key, Future<T> Function() body) {
    final result = Completer<T>();
    final previous = _tails[key] ?? Future<void>.value();
    final done = result.future.then<void>((_) {}, onError: (_) {});
    _tails[key] = done;
    previous.then((_) async {
      try {
        result.complete(await body());
      } catch (e, st) {
        result.completeError(e, st);
      } finally {
        if (identical(_tails[key], done)) _tails.remove(key);
      }
    });
    return result.future;
  }
}
