// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A hue and saturation wheel: hue runs clockwise from the right edge (red),
/// saturation from white at the centre to full at the rim.
class ColorWheel extends StatefulWidget {
  const ColorWheel({
    super.key,
    required this.hue,
    required this.saturation,
    required this.onChanged,
    this.onChangeEnd,
    this.enabled = true,
  });

  final double hue;
  final double saturation;
  final void Function(double hue, double saturation) onChanged;
  final void Function(double hue, double saturation)? onChangeEnd;
  final bool enabled;

  @override
  State<ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<ColorWheel> {
  late double _hue = widget.hue;
  late double _saturation = widget.saturation;
  bool _dragging = false;

  @override
  void didUpdateWidget(ColorWheel old) {
    super.didUpdateWidget(old);
    // While the finger is down the thumb follows the finger, not the light.
    if (!_dragging) {
      _hue = widget.hue;
      _saturation = widget.saturation;
    }
  }

  void _update(Offset local, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final d = local - center;
    final hue = (math.atan2(d.dy, d.dx) * 180 / math.pi + 360) % 360;
    final saturation = (d.distance / radius).clamp(0.0, 1.0);
    setState(() {
      _hue = hue;
      _saturation = saturation;
    });
    widget.onChanged(hue, saturation);
  }

  void _nudge(double degrees) {
    final hue = (_hue + degrees + 360) % 360;
    setState(() => _hue = hue);
    widget.onChanged(hue, _saturation);
    widget.onChangeEnd?.call(hue, _saturation);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, constraints.maxHeight.isFinite ? constraints.maxHeight : 340.0);
        final size = Size.square(side);
        return Semantics(
          label: 'Colour wheel',
          value: 'hue ${_hue.round()} degrees, saturation ${(_saturation * 100).round()} percent',
          increasedValue: 'hue ${((_hue + 15) % 360).round()} degrees',
          decreasedValue: 'hue ${((_hue - 15 + 360) % 360).round()} degrees',
          onIncrease: widget.enabled ? () => _nudge(15) : null,
          onDecrease: widget.enabled ? () => _nudge(-15) : null,
          // The wheel sits in scrolling screens. A plain pan detector loses
          // mostly vertical drags to the scroll view, so the wheel claims a
          // touch as soon as it lands inside the circle.
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              if (widget.enabled)
                _WheelPanRecognizer: GestureRecognizerFactoryWithHandlers<_WheelPanRecognizer>(
                  () => _WheelPanRecognizer(size),
                  (r) {
                    r
                      ..size = size
                      ..dragStartBehavior = DragStartBehavior.down;
                    r.onStart = (d) {
                      _dragging = true;
                      HapticFeedback.selectionClick();
                      _update(d.localPosition, size);
                    };
                    r.onUpdate = (d) => _update(d.localPosition, size);
                    r.onEnd = (_) {
                      _dragging = false;
                      widget.onChangeEnd?.call(_hue, _saturation);
                    };
                    r.onCancel = () => _dragging = false;
                  },
                ),
            },
            child: SizedBox.fromSize(
              size: size,
              child: RepaintBoundary(
                child: CustomPaint(painter: _WheelPainter(_hue, _saturation, enabled: widget.enabled)),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.hue, this.saturation, {required this.enabled});

  final double hue;
  final double saturation;
  final bool enabled;

  static final _sweep = SweepGradient(
    colors: [for (var h = 0; h <= 360; h += 30) HSVColor.fromAHSV(1, h % 360, 1, 1).toColor()],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(center, radius, Paint()..shader = _sweep.createShader(rect));
    canvas.drawCircle(
      center,
      radius,
      Paint()..shader = const RadialGradient(colors: [Colors.white, Color(0x00FFFFFF)]).createShader(rect),
    );
    if (!enabled) {
      canvas.drawCircle(center, radius, Paint()..color = Colors.black.withValues(alpha: 0.55));
    }

    final angle = hue * math.pi / 180;
    final thumb = center + Offset(math.cos(angle), math.sin(angle)) * (saturation * radius);
    final color = HSVColor.fromAHSV(1, hue, saturation, 1).toColor();
    canvas.drawCircle(
      thumb,
      17,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(thumb, 15, Paint()..color = Colors.white);
    canvas.drawCircle(thumb, 11, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.hue != hue || old.saturation != saturation || old.enabled != enabled;
}

/// A pan that wins the gesture arena at once when the touch starts inside
/// the wheel, and competes normally (so the page can scroll) outside it.
class _WheelPanRecognizer extends PanGestureRecognizer {
  _WheelPanRecognizer(this.size);

  Size size;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    final radius = size.shortestSide / 2;
    if ((event.localPosition - size.center(Offset.zero)).distance <= radius) {
      resolvePointer(event.pointer, GestureDisposition.accepted);
    }
  }
}
