// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../color/color_math.dart';
import '../../domain/light.dart';

/// A labelled card around one control.
class ControlCard extends StatelessWidget {
  const ControlCard({super.key, required this.icon, required this.title, this.trailing, required this.child});

  final IconData icon;
  final String title;
  final String? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.85),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall),
                const Spacer(),
                if (trailing != null)
                  Text(trailing!, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
              ],
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class PowerRow extends StatelessWidget {
  const PowerRow({super.key, required this.on, required this.onChanged, this.status});

  final bool on;
  final String? status;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(on ? 'On' : 'Off', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
        if (status != null) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Chip(
              label: Text(status!, overflow: TextOverflow.ellipsis),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
        const Spacer(),
        Transform.scale(
          scale: 1.25,
          child: Switch(
            key: const ValueKey('power-switch'),
            value: on,
            onChanged: (v) {
              HapticFeedback.lightImpact();
              onChanged(v);
            },
          ),
        ),
      ],
    );
  }
}

/// A Hue brightness, 1 to 254, as a whole percentage.
int brightnessPercent(num brightness) => (brightness / 254 * 100).round();

/// Brightness as a percentage, sent as 1 to 254. It holds the dragged value
/// while the finger is down, so a report or poll does not pull the thumb
/// back mid drag. A [compact] slider is the bare slider, for a light tile;
/// otherwise it sits in a card showing the percentage.
class BrightnessSlider extends StatefulWidget {
  const BrightnessSlider({super.key, required this.brightness, required this.onChanged, this.compact = false});

  final int brightness;

  /// Disables the slider when null.
  final ValueChanged<int>? onChanged;
  final bool compact;

  @override
  State<BrightnessSlider> createState() => _BrightnessSliderState();
}

class _BrightnessSliderState extends State<BrightnessSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final value =
        _drag ?? widget.brightness.toDouble().clamp(HueRange.minBrightness, HueRange.maxBrightness).toDouble();
    final onChanged = widget.onChanged;
    final compact = widget.compact;
    final slider = Slider(
      key: ValueKey(compact ? 'tile-brightness' : 'brightness-slider'),
      value: value,
      min: HueRange.minBrightness.toDouble(),
      max: HueRange.maxBrightness.toDouble(),
      label: compact ? null : '${brightnessPercent(value)}%',
      semanticFormatterCallback: (v) => '${brightnessPercent(v)}%',
      onChanged: onChanged == null
          ? null
          : (v) {
              setState(() => _drag = v);
              onChanged(v.round());
            },
      onChangeEnd: onChanged == null
          ? null
          : (v) {
              setState(() => _drag = null);
              onChanged(v.round());
            },
    );
    if (compact) return slider;
    return ControlCard(
      icon: Icons.brightness_6_rounded,
      title: 'Brightness',
      trailing: '${brightnessPercent(value)}%',
      child: slider,
    );
  }
}

/// Warm on the left, cool on the right, in kelvin; sent as mireds.
class TemperatureSlider extends StatefulWidget {
  const TemperatureSlider({
    super.key,
    required this.mireds,
    required this.onChanged,
    this.minMireds = HueRange.minMireds,
    this.maxMireds = HueRange.maxMireds,
  });

  final int mireds;
  final ValueChanged<int> onChanged;

  /// The light's range: the coolest and warmest white it can show.
  final int minMireds;
  final int maxMireds;

  @override
  State<TemperatureSlider> createState() => _TemperatureSliderState();
}

class _TemperatureSliderState extends State<TemperatureSlider> {
  double? _drag;

  int get _lo => widget.minMireds;
  int get _hi => widget.maxMireds;

  // The slider runs over inverted mireds so that left is warm.
  double _toSlider(int mireds) => (_hi + _lo - mireds).toDouble();
  int _toMireds(double v) => (_hi + _lo - v).round();

  @override
  Widget build(BuildContext context) {
    final value = _drag ?? _toSlider(widget.mireds.clamp(_lo, _hi));
    final kelvin = (1000000 / _toMireds(value)).round();
    return ControlCard(
      icon: Icons.thermostat_rounded,
      title: 'Temperature',
      trailing: '${(kelvin / 100).round() * 100} K',
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            height: 8,
            margin: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: LinearGradient(
                colors: [
                  ColorMath.miredsToRgb(_hi),
                  ColorMath.miredsToRgb((_lo + _hi) ~/ 2),
                  ColorMath.miredsToRgb(_lo),
                ],
              ),
            ),
          ),
          Slider(
            key: const ValueKey('temperature-slider'),
            value: value,
            min: _lo.toDouble(),
            max: _hi.toDouble(),
            semanticFormatterCallback: (v) => '${(1000000 / _toMireds(v)).round()} kelvin',
            onChanged: (v) {
              setState(() => _drag = v);
              widget.onChanged(_toMireds(v));
            },
            onChangeEnd: (v) {
              setState(() => _drag = null);
              widget.onChanged(_toMireds(v));
            },
          ),
        ],
      ),
    );
  }
}

/// One-tap colours.
class Swatches extends StatelessWidget {
  const Swatches({super.key, required this.colors, required this.onPick});

  final List<LightColor> colors;
  final ValueChanged<LightColor> onPick;

  static const whites = <LightColor>[WhiteColor(454), WhiteColor(366), WhiteColor(233), WhiteColor(156)];
  static const all = <LightColor>[
    ...whites,
    XyColor(0.675, 0.322),
    XyColor(0.5614, 0.4156),
    XyColor(0.4149, 0.1776),
    XyColor(0.2485, 0.0917),
    XyColor(0.1532, 0.0475),
    XyColor(0.17, 0.7),
  ];

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 12,
    alignment: WrapAlignment.center,
    children: [
      for (final c in colors)
        Semantics(
          button: true,
          label: switch (c) {
            WhiteColor(:final kelvin) => 'White $kelvin K',
            _ => 'Colour',
          },
          child: InkResponse(
            onTap: () => onPick(c),
            radius: 26,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ColorMath.colorOf(c),
                border: Border.all(color: Colors.white24, width: 2),
              ),
            ),
          ),
        ),
    ],
  );
}

/// The bulb's built-in effects, as chips, with a speed slider while one runs.
class EffectsCard extends StatelessWidget {
  const EffectsCard({
    super.key,
    required this.effect,
    required this.speed,
    required this.onEffect,
    required this.onSpeed,
    this.effects = HueEffect.values,
  });

  /// The effects the light supports. None is always offered.
  final List<HueEffect> effects;
  final HueEffect effect;
  final int speed;
  final ValueChanged<HueEffect> onEffect;
  final ValueChanged<int> onSpeed;

  static String label(HueEffect e) => switch (e) {
    HueEffect.none => 'None',
    _ => e.name[0].toUpperCase() + e.name.substring(1),
  };

  static IconData icon(HueEffect e) => switch (e) {
    HueEffect.none => Icons.block_rounded,
    HueEffect.candle => Icons.local_fire_department_outlined,
    HueEffect.fireplace => Icons.fireplace_rounded,
    HueEffect.prism => Icons.looks_rounded,
    HueEffect.sunrise || HueEffect.sunbeam => Icons.wb_twilight_rounded,
    HueEffect.sunset => Icons.nights_stay_rounded,
    HueEffect.sparkle || HueEffect.glisten => Icons.auto_awesome_rounded,
    HueEffect.opal => Icons.bubble_chart_rounded,
    HueEffect.underwater => Icons.water_rounded,
    HueEffect.cosmos => Icons.blur_on_rounded,
    HueEffect.enchant => Icons.flare_rounded,
  };

  @override
  Widget build(BuildContext context) => ControlCard(
    icon: Icons.animation_rounded,
    title: 'Effects',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in [HueEffect.none, ...effects.where((e) => e != HueEffect.none)])
              ChoiceChip(
                avatar: Icon(icon(e), size: 18),
                label: Text(label(e)),
                selected: e == effect,
                onSelected: (_) {
                  HapticFeedback.selectionClick();
                  onEffect(e);
                },
              ),
          ],
        ),
        if (effect != HueEffect.none)
          Row(
            children: [
              const Icon(Icons.speed_rounded, size: 18),
              Expanded(
                child: _EffectSpeedSlider(speed: speed, onChangeEnd: onSpeed),
              ),
            ],
          ),
      ],
    ),
  );
}

/// Effect speed, 0 to 255. The thumb follows the finger and the speed is
/// sent once, when the finger lifts.
class _EffectSpeedSlider extends StatefulWidget {
  const _EffectSpeedSlider({required this.speed, required this.onChangeEnd});

  final int speed;
  final ValueChanged<int> onChangeEnd;

  @override
  State<_EffectSpeedSlider> createState() => _EffectSpeedSliderState();
}

class _EffectSpeedSliderState extends State<_EffectSpeedSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) => Slider(
    key: const ValueKey('effect-speed'),
    value: _drag ?? widget.speed.toDouble().clamp(0, 255),
    max: 255,
    semanticFormatterCallback: (v) => 'speed ${(v / 255 * 100).round()}%',
    onChanged: (v) => setState(() => _drag = v),
    onChangeEnd: (v) {
      setState(() => _drag = null);
      widget.onChangeEnd(v.round());
    },
  );
}
