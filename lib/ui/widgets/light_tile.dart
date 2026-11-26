// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../../color/color_math.dart';
import '../../domain/light.dart';
import 'light_controls.dart';

/// A card for one light that glows in the light's current colour.
class LightTile extends StatelessWidget {
  const LightTile({
    super.key,
    required this.light,
    required this.onPower,
    this.onTap,
    this.onLongPress,
    this.onBrightness,
    this.selected = false,
    this.linkedCount,
    this.onRejoin,
    this.onProfiles,
  });

  /// Opens a quick picker of profiles for this light.
  final VoidCallback? onProfiles;

  /// Set for a cluster member that was changed on its own: rejoins it.
  final VoidCallback? onRejoin;

  /// For a linked cluster: how many lights act as this one.
  final int? linkedCount;

  final Light light;
  final ValueChanged<bool> onPower;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Shown with a ring and a check mark while the user picks lights.
  final bool selected;
  final ValueChanged<int>? onBrightness;

  static String statusOf(Light l) {
    if (!l.reachable && l.state.on == null) return 'Not connected';
    if (!l.reachable) return 'Unreachable';
    if (!l.isOn) return 'Off';
    if (!l.kind.hasBrightness) return 'On';
    return 'On, ${brightnessPercent(l.state.brightness ?? 254)}%';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glow = ColorMath.displayColor(light.state);
    final on = light.isOn;
    final fg = on ? (glow.computeLuminance() > 0.45 ? Colors.black87 : Colors.white) : scheme.onSurface;
    return Semantics(
      container: true,
      label: '${light.name}, ${statusOf(light)}',
      child: AnimatedContainer(
        key: const ValueKey('light-tile'),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: on
                ? [glow, Color.lerp(glow, Colors.black, 0.35)!]
                : [scheme.surfaceContainerHigh, scheme.surfaceContainer],
          ),
          boxShadow: on ? [BoxShadow(color: glow.withValues(alpha: 0.35), blurRadius: 24, spreadRadius: -6)] : null,
          border: selected ? Border.all(color: scheme.primary, width: 3) : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        light.transport == Transport.ble ? Icons.bluetooth_rounded : Icons.router_rounded,
                        size: 16,
                        color: fg.withValues(alpha: 0.7),
                        semanticLabel: light.transport == Transport.ble ? 'Bluetooth' : 'Bridge',
                      ),
                      if (linkedCount != null) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.link_rounded, size: 16, color: fg.withValues(alpha: 0.8)),
                        Text(' $linkedCount', style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 12)),
                      ],
                      if (onRejoin != null)
                        SizedBox.square(
                          dimension: 32,
                          child: IconButton(
                            key: const ValueKey('rejoin'),
                            padding: EdgeInsets.zero,
                            tooltip: 'Detached. Tap to rejoin the cluster',
                            icon: Icon(Icons.link_off_rounded, size: 18, color: fg),
                            onPressed: onRejoin,
                          ),
                        ),
                      if (selected) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.check_circle_rounded, size: 18, color: scheme.primary, semanticLabel: 'Selected'),
                      ],
                      if (light.favorite) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.star_rounded, size: 16, color: fg.withValues(alpha: 0.8)),
                      ],
                      const Spacer(),
                      if (onProfiles != null)
                        SizedBox.square(
                          dimension: 36,
                          child: IconButton(
                            key: const ValueKey('tile-profiles'),
                            padding: EdgeInsets.zero,
                            tooltip: 'Profiles',
                            icon: Icon(Icons.auto_awesome_rounded, size: 18, color: fg.withValues(alpha: 0.85)),
                            onPressed: onProfiles,
                          ),
                        ),
                      Switch(
                        value: on,
                        onChanged: onPower,
                        activeThumbColor: Colors.white,
                        activeTrackColor: Colors.black.withValues(alpha: 0.25),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    light.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(statusOf(light), style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 13)),
                  if (onBrightness != null && light.kind.hasBrightness)
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: fg.withValues(alpha: 0.85),
                        inactiveTrackColor: fg.withValues(alpha: 0.2),
                        thumbColor: fg,
                        overlayShape: SliderComponentShape.noOverlay,
                      ),
                      child: BrightnessSlider(
                        compact: true,
                        brightness: light.state.brightness ?? 254,
                        onChanged: on ? onBrightness : null,
                      ),
                    )
                  else
                    const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
