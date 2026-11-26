// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/capabilities.dart';
import 'package:lumen/domain/light.dart';

void main() {
  const gradientStrip = LightCapabilities(
    lightType: 3,
    minMireds: 153,
    maxMireds: 500,
    dynamicScenes: true,
    dynamicEffects: true,
    gradient: true,
    contentRotation: true,
    effects: {HueEffect.candle, HueEffect.prism},
    gradientModes: {GradientMode.interpolated, GradientMode.segmented},
    gradientOrientation: true,
    gradientOrder: true,
  );

  test('round trips every field through json', () {
    final back = LightCapabilities.fromJson(gradientStrip.toJson());
    expect(back, gradientStrip);
    expect(back.hashCode, gradientStrip.hashCode);
  });

  test('equal capabilities with effects in another order hash the same', () {
    const reordered = LightCapabilities(
      lightType: 3,
      minMireds: 153,
      maxMireds: 500,
      dynamicScenes: true,
      dynamicEffects: true,
      gradient: true,
      contentRotation: true,
      effects: {HueEffect.prism, HueEffect.candle},
      gradientModes: {GradientMode.segmented, GradientMode.interpolated},
      gradientOrientation: true,
      gradientOrder: true,
    );
    expect(reordered, gradientStrip);
    expect(reordered.hashCode, gradientStrip.hashCode);
  });

  test('differing effects or modes are not equal', () {
    const fewerEffects = LightCapabilities(
      lightType: 3,
      minMireds: 153,
      maxMireds: 500,
      dynamicScenes: true,
      dynamicEffects: true,
      gradient: true,
      contentRotation: true,
      effects: {HueEffect.candle},
      gradientModes: {GradientMode.interpolated, GradientMode.segmented},
      gradientOrientation: true,
      gradientOrder: true,
    );
    expect(fewerEffects, isNot(gradientStrip));
    expect(const LightCapabilities(lightType: 3), isNot(const LightCapabilities(lightType: 2)));
  });

  test('json without fields gives an on/off light and skips unknown names', () {
    final caps = LightCapabilities.fromJson({
      'effects': ['candle', 'disco'],
      'gradientModes': ['mirrored', 'zigzag'],
    });
    expect(caps.kind, LightKind.onOff);
    expect(caps.effects, {HueEffect.candle});
    expect(caps.gradientModes, {GradientMode.mirrored});
    expect(caps.gradient, isFalse);
  });

  test('describes the type, range, effects and gradient', () {
    expect(
      gradientStrip.toString(),
      'LightCapabilities(type 3, mireds 153..500, effects 2, gradient true (interpolated, segmented))',
    );
  });
}
