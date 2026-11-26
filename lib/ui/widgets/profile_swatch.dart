// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../../color/color_math.dart';
import '../../domain/home.dart';
import '../../domain/light.dart';

/// A round swatch of a profile's colours: one colour for a preset, a sweep
/// of each light's colour for a scene.
class ProfileSwatch extends StatelessWidget {
  const ProfileSwatch({super.key, required this.profile, this.size = 44});

  final Profile profile;
  final double size;

  static Color colorOf(LightState s) => (s.on ?? true)
      ? ColorMath.displayColor(LightState(on: true, brightness: s.brightness, color: s.color))
      : const Color(0xFF2A2A30);

  @override
  Widget build(BuildContext context) {
    final colors = [for (final s in profile.states.values) colorOf(s)];
    if (colors.isEmpty) colors.add(const Color(0xFF2A2A30));
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.length == 1 ? colors.first : null,
        gradient: colors.length > 1 ? SweepGradient(colors: [...colors, colors.first]) : null,
        border: Border.all(color: Colors.white24, width: size > 30 ? 2 : 1),
      ),
    );
  }
}
