// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../domain/light.dart';
import '../transport/ble/ble_central.dart';
import '../transport/ble/hue_ble_codec.dart';

/// A write the simulated bulb received, for assertions in tests.
class GattWrite {
  const GattWrite(this.characteristic, this.value, {this.withoutResponse = false});

  final String characteristic;
  final Uint8List value;
  final bool withoutResponse;

  @override
  String toString() => 'GattWrite($characteristic, $value${withoutResponse ? ', without response' : ''})';
}

/// A Hue Bluetooth bulb that speaks the real GATT byte protocol. It decodes
/// what the app writes with its own reading of the protocol, so a test that
/// passes against it proves the bytes, not just the calls.
class SimulatedHueBulb {
  SimulatedHueBulb({
    required this.id,
    this.name = 'Hue bulb',
    this.model = 'LCA006',
    this.pairingMode = true,
    bool bonded = false,
    this.inRange = true,
    bool? advertising,
    bool bondedElsewhere = false,
    this.proximitySupported = true,
    this.commissioned = true,
    this.windowExpired = false,
    this.onBridge = false,
    this.bondsOnRead = true,
    this.refusesDiscoverable = false,
    DateTime Function()? clock,
    this.state = const LightState(on: false, brightness: 254, color: WhiteColor(HueRange.defaultMireds)),
    List<int>? capabilities,
    bool hasCapabilities = true,
    this.controlReadable = true,
    this.identifySupported = true,
    List<int>? startup,
    bool hasStartup = true,
    this.appSecurity = false,
    this.securityKey,
    bool hasMinDim = true,
    this.minDimReadable = false,
  }) : bonded = bonded || bondedElsewhere,
       advertising = advertising ?? !bondedElsewhere,
       _clock = clock ?? DateTime.now,
       capabilities = hasCapabilities ? (capabilities ?? capabilitiesFor(model)) : null,
       startup = hasStartup ? (startup ?? defaultStartup) : null,
       minDim = hasMinDim ? [0x01] : null;

  /// An older bulb with none of the optional characteristics: no
  /// capabilities, startup, minimum dim level, identify, proximity pairing
  /// or security key.
  factory SimulatedHueBulb.minimal({
    required String id,
    String name = 'Hue bulb',
    String model = 'LCA001',
    bool pairingMode = true,
    bool bonded = false,
    LightState state = const LightState(on: false, brightness: 254, color: WhiteColor(HueRange.defaultMireds)),
  }) => SimulatedHueBulb(
    id: id,
    name: name,
    model: model,
    pairingMode: pairingMode,
    bonded: bonded,
    state: state,
    hasCapabilities: false,
    hasStartup: false,
    hasMinDim: false,
    identifySupported: false,
    proximitySupported: false,
  );

  /// The service each characteristic belongs to.
  static String serviceOf(String characteristic) => switch (characteristic) {
    HueGatt.model => HueGatt.deviceInfoService,
    HueGatt.name || HueGatt.proximity || HueGatt.makeDiscoverable || HueGatt.securityKey => HueGatt.configService,
    _ => HueGatt.lightService,
  };

  /// The characteristics this bulb offers.
  Set<String> get characteristics => {
    HueGatt.model,
    HueGatt.name,
    HueGatt.makeDiscoverable,
    HueGatt.power,
    HueGatt.brightness,
    HueGatt.temperature,
    HueGatt.xy,
    HueGatt.control,
    if (proximitySupported) HueGatt.proximity,
    if (capabilities != null) HueGatt.capabilities,
    if (startup != null) HueGatt.startup,
    if (minDim != null) HueGatt.minDim,
    if (securityKey != null) HueGatt.securityKey,
    if (identifySupported) HueGatt.identify,
  };

  bool has(String service, String characteristic) =>
      characteristics.contains(characteristic) && serviceOf(characteristic) == service;

  /// Fails as a phone does for a characteristic the bulb does not offer.
  void _requireCharacteristic(String characteristic) {
    if (!characteristics.contains(characteristic)) {
      throw BleOperationException(BleFailure.notFound, 'no characteristic $characteristic', 'characteristicNotFound');
    }
  }

  /// The value of the minimum dim level characteristic 932c32bd-1006, or
  /// null when the bulb does not have it. One byte, scaled as brightness.
  List<int>? minDim;

  /// Whether 1006 can be read. The spec lists it as write-only, so it is not
  /// by default.
  bool minDimReadable;

  /// Uses application-layer security: once bonded, protected reads and
  /// writes are refused without a secure session, which Lumen never opens.
  bool appSecurity;

  /// The value of 97fe6561-2005, or null when the bulb does not have it.
  List<int>? securityKey;

  /// A provisioned key: a 16-byte seed (type 0) and its 32-byte hash (type 1).
  static final provisionedKey = [0x00, 0x10, ...List.filled(16, 0x5A), 0x01, 0x20, ...List.filled(32, 0xA5)];

  /// The characteristic on a light that has no key yet.
  static final emptyKey = [0x00, 0x10, ...List.filled(16, 0x00)];

  /// Characteristics protected by application-layer security (see docs/protocol.md).
  static const _protected = {
    HueGatt.control,
    HueGatt.power,
    HueGatt.brightness,
    HueGatt.temperature,
    HueGatt.xy,
    HueGatt.name,
    HueGatt.startup,
    HueGatt.minDim,
    HueGatt.identify,
  };

  void _requireSession(String characteristic) {
    if (appSecurity && _protected.contains(characteristic)) {
      throw const BleOperationException(
        BleFailure.unauthenticated,
        'insufficient encryption',
        'insufficientEncryption',
      );
    }
  }

  /// The value of the startup characteristic 932c32bd-1005, or null when the
  /// bulb does not have it.
  List<int>? startup;

  /// Power on at full brightness in a warm white, written out by hand.
  static const defaultStartup = [0x01, 0x01, 0x01, 0x02, 0x01, 0xFE, 0x03, 0x02, 0x6E, 0x01];

  /// Checks a startup record the way the spec frames it (section 5.2): only
  /// power (1 byte: 0x00, 0x01 or 0xFF), brightness (1 byte), colour
  /// temperature (2 bytes) and xy (4 bytes) records.
  static bool _validStartup(List<int> v) {
    var i = 0;
    while (i < v.length) {
      if (i + 2 > v.length) return false;
      final (type, length) = (v[i], v[i + 1]);
      if (i + 2 + length > v.length) return false;
      final ok = switch (type) {
        0x01 => length == 1 && const {0x00, 0x01, 0xFF}.contains(v[i + 2]),
        0x02 => length == 1,
        0x03 => length == 2,
        0x04 => length == 4,
        _ => false,
      };
      if (!ok) return false;
      i += 2 + length;
    }
    return true;
  }

  /// The value of the capabilities characteristic 932c32bd-0001, or null
  /// when the bulb does not have it, as on older firmware.
  List<int>? capabilities;

  /// The TLV value of 932c32bd-0001 for a model number, written out by hand
  /// from the wire format (docs/protocol.md) so the app's decoder is checked
  /// against independent bytes: light type (0x00), colour temperature range
  /// (0x01, 0x02), feature flags (0x03), effect bitmask (0x04), gradient
  /// configuration (0x05) and gradient modes (0x08).
  static List<int> capabilitiesFor(String model) {
    const colour = [0x00, 0x01, 0x03, 0x01, 0x02, 0x99, 0x00, 0x02, 0x02, 0xF4, 0x01];
    const effects = [0x04, 0x03, 0x0F, 0xFE, 0x03];
    final m = model.toUpperCase();
    if (m.startsWith('LO')) return const [0x03, 0x01, 0x00];
    if (m.startsWith('LW')) return const [0x00, 0x01, 0x01, 0x03, 0x01, 0x00];
    if (m.startsWith('LT')) {
      return const [0x00, 0x01, 0x02, 0x01, 0x02, 0x99, 0x00, 0x02, 0x02, 0xC6, 0x01, 0x03, 0x01, 0x00];
    }
    if (m.startsWith('LCX')) {
      return const [...colour, 0x03, 0x01, 0x0E, ...effects, 0x05, 0x01, 0x03, 0x08, 0x01, 0x0F];
    }
    return const [...colour, 0x03, 0x01, 0x06, ...effects];
  }

  /// The feature flags record (0x03) of the capabilities says gradient
  /// (bit 3).
  bool get gradientCapable {
    final caps = capabilities;
    if (caps == null) return false;
    for (var i = 0; i + 2 < caps.length; i += 2 + caps[i + 1]) {
      if (caps[i] == 0x03 && caps[i + 1] == 1) return caps[i + 2] & 0x08 != 0;
    }
    return false;
  }

  /// Checks every palette record (0x07) of a control write by hand: a
  /// 4-byte header with the colour count in the high nibble, an even mode
  /// of at most 6, two zero bytes, then exactly 3 bytes per colour.
  static bool _validPalettes(List<int> v) {
    for (var i = 0; i + 1 < v.length; i += 2 + v[i + 1]) {
      if (v[i] != 0x07) continue;
      final length = v[i + 1];
      if (length < 4 || i + 2 + length > v.length) return false;
      final header = v.sublist(i + 2, i + 6);
      final count = header[0] >> 4;
      if (header[0] & 0x0F != 0 || header[1].isOdd || header[1] > 6 || header[2] != 0 || header[3] != 0) return false;
      if (length != 4 + 3 * count) return false;
    }
    return true;
  }

  /// Whether 932c32bd-0007 can be read. Writes and notifications work
  /// either way.
  bool controlReadable;

  /// Has the identify characteristic 932c32bd-0006.
  bool identifySupported;

  /// Refuses a write when it returns an error, as a bulb that does not
  /// answer or rejects it. Nothing is written then.
  BleOperationException? Function(String characteristic, Uint8List value)? refuseWrite;

  /// Blink commands received on 932c32bd-0006.
  int identifies = 0;

  /// Characteristics read so far, in order.
  final List<String> reads = [];

  final String id;
  String name;
  final String model;
  bool pairingMode;
  bool bonded;
  bool inRange;

  /// Has the proximity pairing characteristic 97fe6561-2001.
  bool proximitySupported;
  bool commissioned;

  /// The time window after power-on has passed.
  bool windowExpired;
  bool onBridge;

  /// Reading an encrypted characteristic starts the bond, as on Android.
  bool bondsOnRead;

  /// Refuses "Make discoverable" from a third-party app.
  bool refusesDiscoverable;
  final DateTime Function() _clock;
  DateTime? _discoverableUntil;
  int makeDiscoverableWrites = 0;

  /// In pairing mode, or made discoverable less than five minutes ago.
  bool get openForBonding => pairingMode || (_discoverableUntil?.isAfter(_clock()) ?? false);

  int get proximityFlags =>
      (openForBonding ? 0x01 : 0) |
      (bonded ? 0x02 : 0) |
      (commissioned ? 0 : 0x04) |
      (windowExpired ? 0x08 : 0) |
      (onBridge ? 0x10 : 0);

  /// Whether a scan sees the bulb. A bulb bonded with the phone, for example
  /// by the official app, usually stops advertising.
  bool advertising;
  LightState state;
  final List<GattWrite> writes = [];
  final _reports = StreamController<Uint8List>.broadcast(sync: true);

  Stream<Uint8List> get reports => _reports.stream;

  LightKind get kind => switch (model.substring(0, 2)) {
    'LO' => LightKind.onOff,
    'LW' => LightKind.white,
    'LT' => LightKind.ambiance,
    _ => LightKind.color,
  };

  /// A change made outside the app, such as the official app or a switch.
  /// Sends a report without changing the state, as a bulb does while it
  /// fades from one level to another.
  void report(LightState reported) => _reports.add(
    HueBleCodec.encodeControl(LightCommand(on: reported.on, brightness: reported.brightness, color: reported.color)),
  );

  void changeLocally(LightCommand command) {
    state = state.apply(command);
    _report();
  }

  /// Characteristics that need an encrypted, bonded link.
  static const encrypted = {
    HueGatt.control,
    HueGatt.power,
    HueGatt.brightness,
    HueGatt.temperature,
    HueGatt.xy,
    HueGatt.capabilities,
    HueGatt.startup,
    HueGatt.minDim,
    HueGatt.identify,
  };

  void _requireBond() {
    if (!bonded) {
      throw const BleOperationException(BleFailure.unauthenticated, 'insufficient authentication');
    }
  }

  void bond() {
    if (bonded) return;
    if (!openForBonding) {
      throw const BleOperationException(BleFailure.unauthenticated, 'bulb is not in pairing mode');
    }
    bonded = true;
  }

  Uint8List read(String characteristic) {
    _requireCharacteristic(characteristic);
    reads.add(characteristic);
    switch (characteristic) {
      case HueGatt.model:
        return Uint8List.fromList(utf8.encode(model));
      case HueGatt.name:
        return Uint8List.fromList(utf8.encode(name));
      case HueGatt.proximity:
        return Uint8List.fromList([proximityFlags]);
    }
    // Like Android, reading an encrypted characteristic starts a bond with a
    // bulb in pairing mode.
    if (!bonded && openForBonding && bondsOnRead) bonded = true;
    _requireBond();
    _requireSession(characteristic);
    return switch (characteristic) {
      HueGatt.power => HueBleCodec.encodePower(state.on ?? false),
      HueGatt.brightness => HueBleCodec.encodeBrightness(state.brightness ?? 254),
      HueGatt.temperature => switch (state.color) {
        WhiteColor(:final mireds) => HueBleCodec.encodeMireds(mireds),
        _ => Uint8List.fromList([0xFF, 0xFF]),
      },
      HueGatt.xy => switch (state.color) {
        final XyColor c => HueBleCodec.encodeXy(c),
        _ => Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF]),
      },
      HueGatt.control when controlReadable => _controlReport(),
      HueGatt.capabilities when capabilities != null => Uint8List.fromList(capabilities!),
      HueGatt.startup when startup != null => Uint8List.fromList(startup!),
      HueGatt.securityKey when securityKey != null => Uint8List.fromList(securityKey!),
      HueGatt.minDim when minDim != null && minDimReadable => Uint8List.fromList(minDim!),
      _ => throw BleOperationException(BleFailure.other, 'read not permitted', 'readNotPermitted'),
    };
  }

  void write(String characteristic, Uint8List value, {bool withoutResponse = false}) {
    _requireCharacteristic(characteristic);
    if (refuseWrite?.call(characteristic, value) case final e?) throw e;
    if (characteristic == HueGatt.proximity) {
      writes.add(GattWrite(characteristic, Uint8List.fromList(value), withoutResponse: withoutResponse));
      return;
    }
    _requireBond();
    _requireSession(characteristic);
    if (characteristic == HueGatt.makeDiscoverable) {
      if (refusesDiscoverable) {
        throw const BleOperationException(BleFailure.other, 'write not permitted', 'writeNotPermitted');
      }
      writes.add(GattWrite(characteristic, Uint8List.fromList(value), withoutResponse: withoutResponse));
      makeDiscoverableWrites++;
      _discoverableUntil = _clock().add(const Duration(minutes: 5));
      return;
    }
    writes.add(GattWrite(characteristic, Uint8List.fromList(value), withoutResponse: withoutResponse));
    switch (characteristic) {
      case HueGatt.power:
        state = state.apply(LightCommand(on: HueBleCodec.decodePower(value)));
      case HueGatt.brightness:
        state = state.apply(LightCommand(brightness: HueBleCodec.decodeBrightness(value)));
      case HueGatt.temperature:
        final m = HueBleCodec.decodeMireds(value);
        if (m != null && kind.hasTemperature) state = state.apply(LightCommand(color: WhiteColor(m)));
      case HueGatt.xy:
        final c = HueBleCodec.decodeXy(value);
        if (c != null && kind.hasColor) state = state.apply(LightCommand(color: c));
      case HueGatt.control:
        if (!_validPalettes(value)) {
          writes.removeLast();
          throw const BleOperationException(BleFailure.other, 'invalid palette record', 'writeNotPermitted');
        }
        final s = HueBleCodec.decodeControl(value);
        var color = s.color;
        if (color is XyColor && !kind.hasColor) color = null;
        if (color is WhiteColor && !kind.hasTemperature) color = null;
        state = state.apply(
          LightCommand(
            on: s.on,
            brightness: s.brightness,
            color: color,
            // A new colour without an effect record ends the running effect.
            effect: s.effect ?? (s.color != null ? HueEffect.none : null),
            effectSpeed: s.effectSpeed,
            gradient: gradientCapable ? s.gradient : null,
          ),
        );
      case HueGatt.name:
        if (value.length > 32) {
          writes.removeLast();
          throw const BleOperationException(BleFailure.other, 'name longer than 32 bytes', 'invalidAttributeLength');
        }
        name = utf8.decode(value);
        return;
      case HueGatt.startup when startup != null:
        if (withoutResponse || !_validStartup(value)) {
          writes.removeLast();
          throw const BleOperationException(BleFailure.other, 'invalid startup record', 'writeNotPermitted');
        }
        startup = List.of(value);
        return;
      case HueGatt.minDim when minDim != null:
        if (withoutResponse || value.length != 1 || value[0] < 1 || value[0] > 254) {
          writes.removeLast();
          throw const BleOperationException(BleFailure.other, 'invalid minimum dim level', 'writeNotPermitted');
        }
        minDim = List.of(value);
        return;
      case HueGatt.identify when identifySupported:
        if (value.length != 1 || value[0] != 0x01 || withoutResponse) {
          throw const BleOperationException(BleFailure.other, 'invalid identify command', 'writeNotPermitted');
        }
        identifies++;
        return;
      default:
        // A characteristic that takes no writes: nothing was written.
        writes.removeLast();
        throw const BleOperationException(BleFailure.other, 'write not permitted', 'writeNotPermitted');
    }
    _report();
  }

  void _report() => _reports.add(_controlReport());

  Uint8List _controlReport() => HueBleCodec.encodeControl(
    LightCommand(
      on: state.on,
      brightness: state.brightness,
      color: state.color,
      effect: state.effect == null || state.effect == HueEffect.none ? null : state.effect,
      gradient: state.gradient,
    ),
  );
}

/// A Bluetooth central backed by [SimulatedHueBulb]s.
class SimulatedBleCentral implements BleCentral {
  SimulatedBleCentral({
    this.scanDelay = const Duration(milliseconds: 400),
    this.latency = Duration.zero,
    this.available = true,
    this.permissionGranted = true,
    this.maxConnections = 7,
  });

  /// How many links the simulated phone can hold at once.
  final int maxConnections;

  /// The most links that were ever open at the same time.
  int peakConnections = 0;

  /// Scans running now.
  int scans = 0;

  /// Connections attempted while a scan was running. Many Android phones
  /// fail those with GATT error 133.
  int connectsWhileScanning = 0;

  final Duration scanDelay;
  final Duration latency;
  bool available;
  bool permissionGranted;

  /// Android no longer shows the permission prompt.
  bool permanentlyDenied = false;

  /// Permission prompts shown so far.
  int permissionRequests = 0;
  final Map<String, SimulatedHueBulb> bulbs = {};

  /// Thrown by [pair] instead of bonding, as when Android's createBond fails.
  BleOperationException? pairError;

  /// Thrown by the next calls to [connect], in order.
  final List<BleOperationException> connectErrors = [];

  int pairCalls = 0;

  /// MTUs asked for, in order.
  final List<int> mtuRequests = [];
  final Set<String> connected = {};
  final Map<String, StreamController<bool>> _connection = {};

  /// Every read asked of the central, as (device, characteristic), in order,
  /// including those that fail.
  final List<(String, String)> readRequests = [];

  /// Successful connects, counted per call that opened a link.
  int connects = 0;

  /// [hasCharacteristic] answers true for everything, as a platform that
  /// cannot tell.
  bool reportsAllCharacteristics = false;

  /// Devices whose cached GATT table is stale: their reads and writes fail
  /// with notFound until they have reconnected this many times.
  final Map<String, int> staleGatt = {};

  /// Notification subscriptions the bulbs accepted, as (device,
  /// characteristic), in order.
  final List<(String, String)> subscriptions = [];

  SimulatedHueBulb addBulb(SimulatedHueBulb bulb) => bulbs[bulb.id] = bulb;

  /// The bulb drops the link, as when it loses power or goes out of range.
  void dropConnection(String deviceId) {
    if (connected.remove(deviceId)) _connectionOf(deviceId).add(false);
  }

  StreamController<bool> _connectionOf(String id) =>
      _connection.putIfAbsent(id, () => StreamController<bool>.broadcast(sync: true));

  Future<void> _delay() => latency == Duration.zero ? Future.value() : Future.delayed(latency);

  SimulatedHueBulb _connectedBulb(String id) {
    final bulb = bulbs[id];
    if (bulb == null || !connected.contains(id)) {
      throw const BleOperationException(BleFailure.notConnected);
    }
    return bulb;
  }

  /// The connected bulb, for a read or write of [characteristic] in
  /// [service]. Fails with notFound, as universal_ble does, when the
  /// discovered table lacks it.
  SimulatedHueBulb _gattOf(String id, String service, String characteristic) {
    final bulb = _connectedBulb(id);
    if ((staleGatt[id] ?? 0) > 0) {
      throw BleOperationException(BleFailure.notFound, 'stale GATT table: $characteristic', 'characteristicNotFound');
    }
    if (!bulb.has(service, characteristic)) {
      throw BleOperationException(BleFailure.notFound, 'no characteristic $characteristic', 'characteristicNotFound');
    }
    return bulb;
  }

  @override
  Future<bool> hasCharacteristic(String deviceId, String service, String characteristic) async {
    final bulb = bulbs[deviceId];
    if (bulb == null) return false;
    return reportsAllCharacteristics || bulb.has(service, characteristic);
  }

  @override
  Future<void> ensureReady({bool request = false}) async {
    if (!permissionGranted && request && !permanentlyDenied) permissionRequests++;
    if (!permissionGranted) {
      throw BleOperationException(
        BleFailure.permissionDenied,
        'not granted',
        permanentlyDenied && request ? 'permanentlyDenied' : 'notGranted',
      );
    }
    if (!available) throw const BleOperationException(BleFailure.unavailable);
  }

  @override
  Future<Map<String, String>> status() async => {
    'Bluetooth': available ? 'poweredOn' : 'poweredOff',
    'Permissions': permissionGranted ? 'granted' : 'not granted',
  };

  @override
  Stream<BleAdvert> scan({required List<String> services}) {
    final seen = <String>{};
    Timer? timer;
    var cancelled = false;
    late StreamController<BleAdvert> controller;
    void sweep() {
      for (final bulb in bulbs.values.toList()) {
        if (bulb.inRange && bulb.advertising && seen.add(bulb.id)) {
          controller.add(
            BleAdvert(
              deviceId: bulb.id,
              name: bulb.name,
              rssi: -55,
              services: [HueGatt.advertisedService],
              openForBonding: bulb.openForBonding,
            ),
          );
        }
      }
    }

    controller = StreamController<BleAdvert>(
      onListen: () async {
        try {
          await ensureReady();
        } catch (e) {
          controller.addError(e);
          return;
        }
        if (controller.isClosed || cancelled) return;
        final period = scanDelay == Duration.zero ? const Duration(milliseconds: 1) : scanDelay;
        scans++;
        timer = Timer.periodic(period, (_) => sweep());
      },
      // Async, like the platform's stopScan, and so in the caller's zone:
      // under fake time a cancel that returned the root zone's done future
      // would never resume its awaiter.
      onCancel: () async {
        cancelled = true;
        if (timer != null) scans--;
        timer?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> connect(String deviceId) async {
    if (scans > 0) connectsWhileScanning++;
    await _delay();
    if (connectErrors.isNotEmpty) throw connectErrors.removeAt(0);
    final bulb = bulbs[deviceId];
    if (bulb == null || !bulb.inRange) {
      throw const BleOperationException(BleFailure.unreachable);
    }
    if (connected.contains(deviceId)) return;
    if (connected.length >= maxConnections) {
      throw const BleOperationException(BleFailure.connectionLimit, 'connection limit exceeded');
    }
    connected.add(deviceId);
    connects++;
    if (staleGatt[deviceId] case final n? when n > 0) staleGatt[deviceId] = n - 1;
    if (connected.length > peakConnections) peakConnections = connected.length;
    _connectionOf(deviceId).add(true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    if (connected.remove(deviceId)) _connectionOf(deviceId).add(false);
  }

  @override
  Future<void> pair(String deviceId) async {
    pairCalls++;
    await _delay();
    final bulb = _connectedBulb(deviceId);
    if (pairError case final e?) throw e;
    bulb.bond();
  }

  @override
  Future<bool?> isPaired(String deviceId) async => bulbs[deviceId]?.bonded ?? false;

  @override
  Future<List<BleAdvert>> knownDevices() async => [
    for (final b in bulbs.values)
      if (b.bonded) BleAdvert(deviceId: b.id, name: b.name, services: [HueGatt.lightService]),
  ];

  @override
  Future<Uint8List> read(String deviceId, String service, String characteristic) async {
    readRequests.add((deviceId, characteristic));
    await _delay();
    return _gattOf(deviceId, service, characteristic).read(characteristic);
  }

  @override
  Future<void> write(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    await _delay();
    _gattOf(deviceId, service, characteristic).write(characteristic, value, withoutResponse: withoutResponse);
  }

  @override
  Future<int> requestMtu(String deviceId, int mtu) async {
    _connectedBulb(deviceId);
    mtuRequests.add(mtu);
    return mtu;
  }

  @override
  Stream<Uint8List> notifications(String deviceId, String service, String characteristic) {
    final bulb = bulbs[deviceId];
    if (bulb == null) return const Stream.empty();
    return Stream.multi((out) {
      // Like a real bulb, an encrypted characteristic refuses to notify on
      // a link that is not bonded, and the refusal is final.
      if (SimulatedHueBulb.encrypted.contains(characteristic) && !bulb.bonded) {
        out
          ..addError(const BleOperationException(BleFailure.unauthenticated, 'insufficient authentication'))
          ..close();
        return;
      }
      subscriptions.add((deviceId, characteristic));
      final sub = bulb.reports.where((_) => connected.contains(deviceId)).listen(out.add);
      out.onCancel = sub.cancel;
    });
  }

  @override
  Stream<bool> connectionChanges(String deviceId) => _connectionOf(deviceId).stream;
}
