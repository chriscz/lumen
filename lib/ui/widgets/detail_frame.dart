// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../../color/color_math.dart';
import '../../domain/light.dart';
import 'color_wheel.dart';

/// The body of a detail screen: a list of controls under a glow in the
/// colour of the light, brighter while it is on.
class DetailFrame extends StatelessWidget {
  const DetailFrame({super.key, required this.glow, required this.on, required this.children});

  final Color glow;
  final bool on;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 500),
    decoration: BoxDecoration(
      gradient: RadialGradient(
        center: const Alignment(0, -1.1),
        radius: 1.3,
        colors: [
          glow.withValues(alpha: on ? 0.55 : 0.15),
          Theme.of(context).colorScheme.surface,
        ],
      ),
    ),
    child: SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: children),
    ),
  );
}

/// The Colour or White switch and, in colour, the colour wheel. The wheel
/// reports where the thumb is and that colour clamped to the lights' gamut.
class WheelCard extends StatelessWidget {
  const WheelCard({
    super.key,
    required this.white,
    required this.onWhite,
    required this.showToggle,
    required this.showWheel,
    required this.hue,
    required this.saturation,
    required this.onColor,
  });

  final bool white;
  final ValueChanged<bool> onWhite;
  final bool showToggle;
  final bool showWheel;
  final double hue;
  final double saturation;
  final void Function(double hue, double saturation, XyColor color) onColor;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (showToggle)
        Center(
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.palette_rounded), label: Text('Colour')),
              ButtonSegment(value: true, icon: Icon(Icons.wb_sunny_rounded), label: Text('White')),
            ],
            selected: {white},
            onSelectionChanged: (s) => onWhite(s.first),
          ),
        ),
      const SizedBox(height: 20),
      if (showWheel)
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
            child: AspectRatio(
              aspectRatio: 1,
              child: ColorWheel(
                key: const ValueKey('color-wheel'),
                hue: hue,
                saturation: saturation,
                onChanged: (h, s) => onColor(h, s, ColorMath.clampToGamut(ColorMath.hueSatToXy(h, s), Gamut.c)),
              ),
            ),
          ),
        ),
    ],
  );
}
