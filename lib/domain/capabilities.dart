// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'light.dart';

/// How a gradient light blends its colour points. The enum index matches the
/// BLE GATT wire mode index, which the palette header carries doubled.
enum GradientMode { interpolated, random, mirrored, segmented }

/// What a Hue Bluetooth light says it can do, read from its capabilities
/// characteristic `932c32bd-0001` (see docs/protocol.md).
class LightCapabilities {
  const LightCapabilities({
    this.lightType,
    this.minMireds,
    this.maxMireds,
    this.dynamicScenes = false,
    this.dynamicEffects = false,
    this.gradient = false,
    this.contentRotation = false,
    this.effects = const {},
    this.gradientModes = const {},
    this.gradientOrientation = false,
    this.gradientOrder = false,
  });

  /// The light type record: 1 dimmable, 2 white ambiance, 3 colour. Null
  /// when the record is missing, which means an on/off light.
  final int? lightType;
  final int? minMireds;
  final int? maxMireds;
  final bool dynamicScenes;
  final bool dynamicEffects;
  final bool gradient;
  final bool contentRotation;

  /// Built-in effects the light supports, without [HueEffect.none].
  final Set<HueEffect> effects;
  final Set<GradientMode> gradientModes;
  final bool gradientOrientation;
  final bool gradientOrder;

  /// The kind the light type gives, or null for a type the spec does not
  /// name, so the caller can fall back to another source.
  LightKind? get kind => switch (lightType) {
    null => LightKind.onOff,
    1 => LightKind.white,
    2 => LightKind.ambiance,
    3 => LightKind.color,
    _ => null,
  };

  Map<String, Object?> toJson() => {
    'lightType': lightType,
    'minMireds': minMireds,
    'maxMireds': maxMireds,
    'dynamicScenes': dynamicScenes,
    'dynamicEffects': dynamicEffects,
    'gradient': gradient,
    'contentRotation': contentRotation,
    'effects': [for (final e in effects) e.name],
    'gradientModes': [for (final m in gradientModes) m.name],
    'gradientOrientation': gradientOrientation,
    'gradientOrder': gradientOrder,
  };

  factory LightCapabilities.fromJson(Map<String, Object?> json) {
    final effectNames = HueEffect.values.asNameMap();
    final modeNames = GradientMode.values.asNameMap();
    return LightCapabilities(
      lightType: json['lightType'] as int?,
      minMireds: json['minMireds'] as int?,
      maxMireds: json['maxMireds'] as int?,
      dynamicScenes: json['dynamicScenes'] as bool? ?? false,
      dynamicEffects: json['dynamicEffects'] as bool? ?? false,
      gradient: json['gradient'] as bool? ?? false,
      contentRotation: json['contentRotation'] as bool? ?? false,
      effects: {for (final n in json['effects'] as List? ?? const []) ?effectNames[n]},
      gradientModes: {for (final n in json['gradientModes'] as List? ?? const []) ?modeNames[n]},
      gradientOrientation: json['gradientOrientation'] as bool? ?? false,
      gradientOrder: json['gradientOrder'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LightCapabilities &&
      other.lightType == lightType &&
      other.minMireds == minMireds &&
      other.maxMireds == maxMireds &&
      other.dynamicScenes == dynamicScenes &&
      other.dynamicEffects == dynamicEffects &&
      other.gradient == gradient &&
      other.contentRotation == contentRotation &&
      other.effects.length == effects.length &&
      other.effects.containsAll(effects) &&
      other.gradientModes.length == gradientModes.length &&
      other.gradientModes.containsAll(gradientModes) &&
      other.gradientOrientation == gradientOrientation &&
      other.gradientOrder == gradientOrder;

  @override
  int get hashCode => Object.hash(
    lightType,
    minMireds,
    maxMireds,
    dynamicScenes,
    dynamicEffects,
    gradient,
    contentRotation,
    effects.length,
    gradientModes.length,
    gradientOrientation,
    gradientOrder,
  );

  @override
  String toString() =>
      'LightCapabilities(type $lightType, mireds $minMireds..$maxMireds, effects ${effects.length}, '
      'gradient $gradient ${gradientModes.map((m) => m.name)})';
}
