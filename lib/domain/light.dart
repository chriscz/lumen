// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'capabilities.dart';

/// How the app reaches a light.
enum Transport { ble, bridge }

/// What a light can do. On/off lights only switch, white-only bulbs ignore
/// colour, white ambiance bulbs take colour temperature only.
enum LightKind {
  onOff,
  white,
  ambiance,
  color;

  bool get hasColor => this == color;
  bool get hasTemperature => this == ambiance || this == color;
  bool get hasBrightness => this != onOff;
}

/// The colour part of a light's state: either a point on the CIE xy chart or
/// a white colour temperature in mireds.
sealed class LightColor {
  const LightColor();

  Map<String, Object> toJson();

  static LightColor? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['mireds'] case final int mireds) return WhiteColor(mireds);
    if (json['x'] case final num x) return XyColor(x.toDouble(), (json['y'] as num).toDouble());
    return null;
  }
}

final class XyColor extends LightColor {
  const XyColor(this.x, this.y);

  final double x;
  final double y;

  @override
  Map<String, Object> toJson() => {'x': x, 'y': y};

  @override
  bool operator ==(Object other) => other is XyColor && (other.x - x).abs() < 1e-4 && (other.y - y).abs() < 1e-4;

  @override
  int get hashCode => Object.hash((x * 1e4).round(), (y * 1e4).round());

  @override
  String toString() => 'XyColor(${x.toStringAsFixed(4)}, ${y.toStringAsFixed(4)})';
}

final class WhiteColor extends LightColor {
  const WhiteColor(this.mireds);

  /// Reciprocal megakelvin: 153 is 6500 K (cool), 500 is 2000 K (warm).
  final int mireds;

  int get kelvin => (1000000 / mireds).round();

  @override
  Map<String, Object> toJson() => {'mireds': mireds};

  @override
  bool operator ==(Object other) => other is WhiteColor && other.mireds == mireds;

  @override
  int get hashCode => mireds.hashCode;

  @override
  String toString() => 'WhiteColor($mireds)';
}

/// The built-in effects of Hue Bluetooth bulbs, with their protocol ids.
enum HueEffect {
  none(0x00),
  candle(0x01),
  fireplace(0x02),
  prism(0x03),
  sunrise(0x09),
  sparkle(0x0A),
  opal(0x0B),
  glisten(0x0C),
  sunset(0x0D),
  underwater(0x0E),
  cosmos(0x0F),
  sunbeam(0x10),
  enchant(0x11);

  const HueEffect(this.id);

  final int id;

  static HueEffect fromId(int id) => values.firstWhere((e) => e.id == id, orElse: () => HueEffect.none);
}

/// The colours of a gradient light and how it blends them (combined control
/// TLV palette record 0x07, window 0x09, and angle 0x0B).
class LightGradient {
  const LightGradient(this.colors, {this.mode = GradientMode.interpolated, this.window, this.angle});

  /// The colour points, in order along the light.
  final List<XyColor> colors;
  final GradientMode mode;

  /// The part of the light the gradient covers, as fractions from 0 to 1.
  final (double, double)? window;

  /// Rotation in radians.
  final double? angle;

  /// The colour points the app lets a user set.
  static const minColors = 2;
  static const maxColors = 5;

  LightGradient copyWith({List<XyColor>? colors, GradientMode? mode}) =>
      LightGradient(colors ?? this.colors, mode: mode ?? this.mode, window: window, angle: angle);

  Map<String, Object?> toJson() => {
    'colors': [for (final c in colors) c.toJson()],
    'mode': mode.name,
  };

  static LightGradient? fromJson(Object? json) {
    if (json is! Map) return null;
    final colors = [
      for (final c in json['colors'] as List? ?? const [])
        if (LightColor.fromJson(c) case final XyColor xy) xy,
    ];
    if (colors.isEmpty) return null;
    return LightGradient(colors, mode: GradientMode.values.asNameMap()[json['mode']] ?? GradientMode.interpolated);
  }

  @override
  bool operator ==(Object other) =>
      other is LightGradient &&
      other.mode == mode &&
      other.window == window &&
      other.angle == angle &&
      other.colors.length == colors.length &&
      [for (var i = 0; i < colors.length; i++) other.colors[i] == colors[i]].every((same) => same);

  @override
  int get hashCode => Object.hash(mode, window, angle, Object.hashAll(colors));

  @override
  String toString() => 'LightGradient(${mode.name}, $colors)';
}

/// A change to send to a light. Null fields are left as they are.
class LightCommand {
  const LightCommand({
    this.on,
    this.brightness,
    this.color,
    this.transition,
    this.effect,
    this.effectSpeed,
    this.gradient,
  });

  final bool? on;
  final int? brightness;
  final LightColor? color;
  final Duration? transition;
  final HueEffect? effect;
  final int? effectSpeed;

  /// A gradient for a gradient light. A plain [color] replaces a gradient.
  final LightGradient? gradient;

  bool get isEmpty =>
      on == null && brightness == null && color == null && effect == null && effectSpeed == null && gradient == null;

  /// Layers [next] on top of this command, so two queued commands become one.
  /// A later colour without an effect ends an effect, so the earlier pending
  /// effect and its speed are dropped rather than sent again.
  LightCommand merge(LightCommand next) {
    final endsEffect = next.color != null && next.effect == null;
    return LightCommand(
      on: next.on ?? on,
      brightness: next.brightness ?? brightness,
      color: next.color ?? color,
      transition: next.transition ?? transition,
      effect: next.effect ?? (endsEffect ? null : effect),
      effectSpeed: next.effectSpeed ?? (endsEffect ? null : effectSpeed),
      gradient: next.gradient ?? (next.color != null ? null : gradient),
    );
  }

  /// This command with [color] in place of its colour.
  LightCommand withColor(LightColor? color) => LightCommand(
    on: on,
    brightness: brightness,
    color: color,
    transition: transition,
    effect: effect,
    effectSpeed: effectSpeed,
    gradient: gradient,
  );

  @override
  bool operator ==(Object other) =>
      other is LightCommand &&
      other.on == on &&
      other.brightness == brightness &&
      other.color == color &&
      other.transition == transition &&
      other.effect == effect &&
      other.effectSpeed == effectSpeed &&
      other.gradient == gradient;

  @override
  int get hashCode => Object.hash(on, brightness, color, transition, effect, effectSpeed, gradient);

  @override
  String toString() =>
      'LightCommand(on: $on, bri: $brightness, color: $color, effect: $effect${gradient == null ? '' : ', $gradient'})';
}

/// A light's state as last reported or set. Every field is optional because
/// a report can carry only some of them.
class LightState {
  const LightState({this.on, this.brightness, this.color, this.effect, this.effectSpeed, this.gradient});

  final bool? on;
  final int? brightness;
  final LightColor? color;
  final HueEffect? effect;
  final int? effectSpeed;

  /// The gradient a gradient light shows, or null when it shows one colour.
  final LightGradient? gradient;

  static const unknown = LightState();

  /// This state after [c]. A colour without an effect ends the running
  /// effect, as the bulb does.
  LightState apply(LightCommand c) => LightState(
    on: c.on ?? on,
    brightness: c.brightness ?? brightness,
    color: c.color ?? color,
    effect: c.effect ?? (c.color != null ? HueEffect.none : effect),
    effectSpeed: c.effectSpeed ?? effectSpeed,
    gradient: c.gradient ?? (c.color != null ? null : gradient),
  );

  LightState mergeReport(LightState report) => LightState(
    on: report.on ?? on,
    brightness: report.brightness ?? brightness,
    color: report.color ?? color,
    effect: report.effect ?? effect,
    effectSpeed: report.effectSpeed ?? effectSpeed,
    gradient: report.gradient ?? (report.color != null ? null : gradient),
  );

  /// The command that reproduces this state, used by profiles.
  LightCommand toCommand({Duration? transition}) =>
      LightCommand(on: on, brightness: brightness, color: color, transition: transition);

  Map<String, Object?> toJson() => {
    'on': on,
    'brightness': brightness,
    'color': color?.toJson(),
    'effect': effect?.name,
    if (gradient != null) 'gradient': gradient!.toJson(),
  };

  factory LightState.fromJson(Map<String, Object?> json) => LightState(
    on: json['on'] as bool?,
    brightness: json['brightness'] as int?,
    color: LightColor.fromJson(json['color']),
    effect: switch (json['effect']) {
      final String name => HueEffect.values.asNameMap()[name],
      _ => null,
    },
    gradient: LightGradient.fromJson(json['gradient']),
  );

  @override
  bool operator ==(Object other) =>
      other is LightState &&
      other.gradient == gradient &&
      other.on == on &&
      other.brightness == brightness &&
      other.color == color &&
      other.effect == effect &&
      other.effectSpeed == effectSpeed;

  @override
  int get hashCode => Object.hash(on, brightness, color, effect, effectSpeed, gradient);

  @override
  String toString() =>
      'LightState(on: $on, bri: $brightness, color: $color, effect: $effect${gradient == null ? '' : ', $gradient'})';
}

/// Brightness and mired limits shared by both transports.
abstract final class HueRange {
  static const minBrightness = 1;
  static const maxBrightness = 254;
  static const minMireds = 153;
  static const maxMireds = 500;

  /// The warm white (about 2700 K) shown and sent when a light reports no
  /// colour.
  static const defaultMireds = 366;

  static int brightness(int value) => value.clamp(minBrightness, maxBrightness);
  static int mireds(int value) => value.clamp(minMireds, maxMireds);
}

/// A light the user has added to the app.
class Light {
  const Light({
    required this.id,
    required this.name,
    required this.transport,
    required this.address,
    this.kind = LightKind.color,
    this.state = LightState.unknown,
    this.reachable = false,
    this.roomId,
    this.favorite = false,
    this.capabilities,
    this.powerOnConfigurable = false,
    this.minDimConfigurable = false,
    this.minDimLevel,
  });

  /// The minimum dim level Lumen last wrote, from 0 to 1. The bulb's
  /// characteristic is write-only, so this is the only value the app knows.
  final double? minDimLevel;

  /// The light has the minimum dim level characteristic.
  final bool minDimConfigurable;

  /// The light has the startup characteristic, so its power-on behaviour
  /// can be set.
  final bool powerOnConfigurable;

  /// What a Bluetooth light reported it can do; null when unknown.
  final LightCapabilities? capabilities;

  /// The colour temperatures the light can show, in mireds.
  (int, int) get miredsRange {
    final lo = capabilities?.minMireds ?? HueRange.minMireds;
    final hi = capabilities?.maxMireds ?? HueRange.maxMireds;
    return lo < hi ? (lo, hi) : (HueRange.minMireds, HueRange.maxMireds);
  }

  /// Stable id inside the app, for example `ble:aa:bb:..` or `bridge:<id>:3`.
  final String id;
  final String name;
  final Transport transport;

  /// The BLE device id, or the bridge's light id.
  final String address;
  final LightKind kind;
  final LightState state;
  final bool reachable;
  final String? roomId;
  final bool favorite;

  bool get isOn => state.on ?? false;

  /// The bridge a bridge light belongs to, from its address `<bridge>/<light>`;
  /// null for a Bluetooth light.
  String? get bridgeId => transport == Transport.bridge ? address.split('/').first : null;

  /// The light's own id on its bridge; null for a Bluetooth light.
  String? get bridgeLightId => transport == Transport.bridge ? address.split('/').last : null;

  /// The built-in effects the light offers, in protocol order, without none.
  /// Effects are a feature of the Bluetooth protocol: a bulb that reported
  /// its capabilities offers the effects it lists; one that did not offers
  /// every effect when it is a colour bulb.
  List<HueEffect> get effects => transport != Transport.ble
      ? const []
      : [
          for (final e in HueEffect.values)
            if (e != HueEffect.none && (capabilities == null ? kind.hasColor : capabilities!.effects.contains(e))) e,
        ];

  /// Gradients are a feature of gradient lights that report it in their
  /// capabilities.
  bool get supportsGradient => transport == Transport.ble && (capabilities?.gradient ?? false);

  /// The gradient modes the light lists, in protocol order. A gradient light
  /// that lists none gets interpolated, the plain blend.
  List<GradientMode> get gradientModes {
    final modes = capabilities?.gradientModes ?? const {};
    if (modes.isEmpty) return const [GradientMode.interpolated];
    return [
      for (final m in GradientMode.values)
        if (modes.contains(m)) m,
    ];
  }

  Light copyWith({
    String? name,
    LightKind? kind,
    LightState? state,
    bool? reachable,
    String? Function()? roomId,
    bool? favorite,
    LightCapabilities? capabilities,
    bool? powerOnConfigurable,
    bool? minDimConfigurable,
    double? minDimLevel,
  }) => Light(
    id: id,
    name: name ?? this.name,
    transport: transport,
    address: address,
    kind: kind ?? this.kind,
    state: state ?? this.state,
    reachable: reachable ?? this.reachable,
    roomId: roomId == null ? this.roomId : roomId(),
    favorite: favorite ?? this.favorite,
    capabilities: capabilities ?? this.capabilities,
    powerOnConfigurable: powerOnConfigurable ?? this.powerOnConfigurable,
    minDimConfigurable: minDimConfigurable ?? this.minDimConfigurable,
    minDimLevel: minDimLevel ?? this.minDimLevel,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'transport': transport.name,
    'address': address,
    'kind': kind.name,
    'state': state.toJson(),
    'roomId': roomId,
    'favorite': favorite,
    if (capabilities != null) 'capabilities': capabilities!.toJson(),
    if (powerOnConfigurable) 'powerOnConfigurable': true,
    if (minDimConfigurable) 'minDimConfigurable': true,
    if (minDimLevel != null) 'minDimLevel': minDimLevel,
  };

  factory Light.fromJson(Map<String, Object?> json) => Light(
    id: json['id'] as String,
    name: json['name'] as String,
    transport: Transport.values.byName(json['transport'] as String),
    address: json['address'] as String,
    kind: LightKind.values.asNameMap()[json['kind']] ?? LightKind.color,
    state: json['state'] is Map
        ? LightState.fromJson((json['state'] as Map).cast<String, Object?>())
        : LightState.unknown,
    roomId: json['roomId'] as String?,
    favorite: json['favorite'] as bool? ?? false,
    capabilities: json['capabilities'] is Map
        ? LightCapabilities.fromJson((json['capabilities'] as Map).cast<String, Object?>())
        : null,
    powerOnConfigurable: json['powerOnConfigurable'] as bool? ?? false,
    minDimConfigurable: json['minDimConfigurable'] as bool? ?? false,
    minDimLevel: (json['minDimLevel'] as num?)?.toDouble(),
  );

  @override
  String toString() => 'Light($id, $name, $state)';
}
