// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../../color/color_math.dart';
import '../../domain/light.dart';

/// A checklist of lights.
class LightPicker extends StatelessWidget {
  const LightPicker({super.key, required this.lights, required this.selected, required this.onChanged, this.subtitle});

  final List<Light> lights;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final String? Function(Light)? subtitle;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final l in lights)
        CheckboxListTile(
          value: selected.contains(l.id),
          title: Text(l.name),
          subtitle: switch (subtitle?.call(l)) {
            final String s => Text(s),
            null => null,
          },
          secondary: CircleAvatar(radius: 14, backgroundColor: ColorMath.displayColor(l.state)),
          onChanged: (v) => onChanged(v == true ? ({...selected, l.id}) : ({...selected}..remove(l.id))),
        ),
    ],
  );
}
