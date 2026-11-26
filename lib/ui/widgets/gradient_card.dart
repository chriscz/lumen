// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../color/color_math.dart';
import '../../domain/capabilities.dart';
import '../../domain/light.dart';
import 'color_wheel.dart';
import 'light_controls.dart';

/// The colour stops of a gradient light, with the blend modes it supports.
/// Every change goes out as one gradient.
class GradientCard extends StatelessWidget {
  const GradientCard({super.key, required this.gradient, required this.modes, required this.onChanged});

  /// The gradient the light shows, or null when it shows one colour.
  final LightGradient? gradient;
  final List<GradientMode> modes;
  final ValueChanged<LightGradient> onChanged;

  /// Where a new gradient starts: red, pink and blue.
  static const starter = LightGradient([XyColor(0.675, 0.322), XyColor(0.4149, 0.1776), XyColor(0.1532, 0.0475)]);

  /// More stops are added from these, in turn.
  static const _extra = [XyColor(0.17, 0.7), XyColor(0.5614, 0.4156), XyColor(0.2485, 0.0917)];

  static String label(GradientMode m) => switch (m) {
    GradientMode.interpolated => 'Blended',
    GradientMode.random => 'Random',
    GradientMode.mirrored => 'Mirrored',
    GradientMode.segmented => 'Segmented',
  };

  LightGradient get _current {
    final g = gradient ?? starter;
    final colors = g.colors.take(LightGradient.maxColors).toList();
    while (colors.length < LightGradient.minColors) {
      colors.add(_extra[colors.length]);
    }
    return g.copyWith(colors: colors, mode: modes.contains(g.mode) ? g.mode : modes.first);
  }

  Future<void> _edit(BuildContext context, int index) async {
    final g = _current;
    final picked = await showDialog<XyColor>(
      context: context,
      builder: (_) => _StopDialog(initial: g.colors[index], index: index),
    );
    if (picked == null) return;
    onChanged(g.copyWith(colors: [...g.colors]..[index] = picked));
  }

  @override
  Widget build(BuildContext context) {
    final g = _current;
    final scheme = Theme.of(context).colorScheme;
    return ControlCard(
      icon: Icons.gradient_rounded,
      title: 'Gradient',
      trailing: '${g.colors.length} colours',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Container(
            key: const ValueKey('gradient-preview'),
            height: 14,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              gradient: LinearGradient(colors: [for (final c in g.colors) ColorMath.colorOf(c)]),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (var i = 0; i < g.colors.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Semantics(
                    button: true,
                    label: 'Colour ${i + 1}',
                    child: InkResponse(
                      key: ValueKey('gradient-stop-$i'),
                      radius: 24,
                      onTap: () => _edit(context, i),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: ColorMath.colorOf(g.colors[i]),
                          border: Border.all(color: scheme.outline, width: 2),
                        ),
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              IconButton(
                key: const ValueKey('gradient-remove'),
                tooltip: 'Remove a colour',
                icon: const Icon(Icons.remove_circle_outline_rounded),
                onPressed: g.colors.length > LightGradient.minColors
                    ? () => onChanged(g.copyWith(colors: g.colors.sublist(0, g.colors.length - 1)))
                    : null,
              ),
              IconButton(
                key: const ValueKey('gradient-add'),
                tooltip: 'Add a colour',
                icon: const Icon(Icons.add_circle_outline_rounded),
                onPressed: g.colors.length < LightGradient.maxColors
                    ? () => onChanged(g.copyWith(colors: [...g.colors, _extra[g.colors.length % _extra.length]]))
                    : null,
              ),
            ],
          ),
          if (modes.length > 1) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in modes)
                  ChoiceChip(
                    key: ValueKey('gradient-mode-${m.name}'),
                    label: Text(label(m)),
                    selected: m == g.mode,
                    onSelected: (_) {
                      HapticFeedback.selectionClick();
                      onChanged(g.copyWith(mode: m));
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

/// Picks one stop's colour on the wheel.
class _StopDialog extends StatefulWidget {
  const _StopDialog({required this.initial, required this.index});

  final XyColor initial;
  final int index;

  @override
  State<_StopDialog> createState() => _StopDialogState();
}

class _StopDialogState extends State<_StopDialog> {
  late (double, double) _hueSat = ColorMath.xyToHueSat(widget.initial);

  XyColor get _color => ColorMath.clampToGamut(ColorMath.hueSatToXy(_hueSat.$1, _hueSat.$2), Gamut.c);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Colour ${widget.index + 1}'),
    content: SizedBox(
      width: 260,
      height: 260,
      child: ColorWheel(
        key: const ValueKey('gradient-wheel'),
        hue: _hueSat.$1,
        saturation: _hueSat.$2,
        onChanged: (h, s) => setState(() => _hueSat = (h, s)),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        key: const ValueKey('gradient-done'),
        onPressed: () => Navigator.pop(context, _color),
        child: const Text('Done'),
      ),
    ],
  );
}
