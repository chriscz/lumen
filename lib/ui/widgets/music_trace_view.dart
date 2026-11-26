// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../music/beat_tracker.dart';
import '../../music/music_trace.dart';

/// The last five seconds of music sync: the onset signal as bars with the
/// threshold an onset must cross as a line, the loudness as a faint fill, a
/// tick for each onset, a mark for each beat (filled when fired, a ring
/// when held, a triangle for a hit, a cross when dropped) and breathing as
/// a shaded band. Repaints on its own whenever the trace gets a chunk.
class MusicTraceView extends StatefulWidget {
  const MusicTraceView({super.key, required this.trace, required this.active});

  final MusicTrace trace;
  final bool active;

  @override
  State<MusicTraceView> createState() => _MusicTraceViewState();
}

class _MusicTraceViewState extends State<MusicTraceView> {
  // Made once and reused on every paint: the layout's buffers, the paints
  // and the level's path.
  final _layout = TraceLayout();
  final _level = Path();
  final _band = Paint();
  final _fill = Paint();
  final _bar = Paint()..strokeWidth = 2;
  final _threshold = Paint()
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke;
  final _hit = Paint()
    ..strokeWidth = 1
    ..style = PaintingStyle.stroke;
  final _tick = Paint()..strokeWidth = 2;
  final _beat = Paint()..strokeWidth = 2;
  final _triangle = Path();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _band.color = scheme.primaryContainer;
    _fill.color = scheme.primary.withValues(alpha: 0.12);
    _bar.color = scheme.primary;
    _threshold.color = scheme.error;
    _tick.color = scheme.tertiary;
    _hit.color = scheme.tertiary;
    _beat.color = scheme.secondary;
    return SizedBox(
      key: const ValueKey('music-trace'),
      height: 96,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: RepaintBoundary(child: CustomPaint(painter: _TracePainter(this))),
        ),
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  _TracePainter(this.s) : trace = s.widget.trace, active = s.widget.active, super(repaint: s.widget.trace);

  final _MusicTraceViewState s;
  final MusicTrace trace;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    if (!active) return;
    final m = s._layout..update(trace, size);
    for (var k = 0; k < m.breathCount; k++) {
      canvas.drawRect(Rect.fromLTRB(m.breathSpans[k * 2], 0, m.breathSpans[k * 2 + 1], size.height), s._band);
    }
    if (m.levelCount > 1) {
      final path = s._level
        ..reset()
        ..moveTo(m.levelPoints[0], size.height);
      for (var k = 0; k < m.levelCount; k++) {
        path.lineTo(m.levelPoints[k * 2], m.levelPoints[k * 2 + 1]);
      }
      path
        ..lineTo(m.levelPoints[(m.levelCount - 1) * 2], size.height)
        ..close();
      canvas.drawPath(path, s._fill);
    }
    if (m.barCount > 0) {
      canvas.drawRawPoints(PointMode.lines, Float32List.sublistView(m.bars, 0, m.barCount * 4), s._bar);
    }
    if (m.thresholdCount > 1) {
      canvas.drawRawPoints(
        PointMode.polygon,
        Float32List.sublistView(m.thresholdPoints, 0, m.thresholdCount * 2),
        s._threshold,
      );
    }
    if (m.hitCount > 1) {
      canvas.drawRawPoints(PointMode.polygon, Float32List.sublistView(m.hitPoints, 0, m.hitCount * 2), s._hit);
    }
    for (var k = 0; k < m.onsetCount; k++) {
      final x = m.onsetXs[k];
      canvas.drawLine(Offset(x, size.height), Offset(x, size.height - 6), s._tick);
    }
    const y = 12.0;
    final beat = s._beat;
    for (var k = 0; k < m.beatCount; k++) {
      drawBeatMark(canvas, Offset(m.beatXs[k], y), BeatOutcome.values[m.beatKinds[k]], beat, s._triangle);
    }
  }

  @override
  bool shouldRepaint(_TracePainter old) => old.trace != trace || old.active != active;
}

/// Draws a beat's mark centred on [at]: a dot when fired, a ring when held,
/// a triangle for a hit, a cross when dropped. [scratch] is a path to reuse.
void drawBeatMark(Canvas canvas, Offset at, BeatOutcome outcome, Paint paint, Path scratch) {
  final Offset(dx: x, dy: y) = at;
  switch (outcome) {
    case BeatOutcome.fired:
      canvas.drawCircle(at, 5, paint..style = PaintingStyle.fill);
    case BeatOutcome.held:
      canvas.drawCircle(at, 5, paint..style = PaintingStyle.stroke);
    case BeatOutcome.hit:
      scratch
        ..reset()
        ..moveTo(x, y - 5)
        ..lineTo(x + 5, y + 4)
        ..lineTo(x - 5, y + 4)
        ..close();
      canvas.drawPath(scratch, paint..style = PaintingStyle.fill);
    case BeatOutcome.busy || BeatOutcome.tooSoon:
      canvas.drawLine(Offset(x - 4, y - 4), Offset(x + 4, y + 4), paint);
      canvas.drawLine(Offset(x - 4, y + 4), Offset(x + 4, y - 4), paint);
  }
}

/// What each mark on the trace means, each drawn as the trace draws it.
class TraceGuide extends StatelessWidget {
  const TraceGuide({super.key});

  static const entries = [
    (_Mark.beat, 'Beat: predicted and sent to the lights'),
    (_Mark.held, 'Held beat: kept after the beat was lost'),
    (_Mark.hit, 'Hit: sent as soon as it was heard'),
    (_Mark.dropped, 'Dropped: the lights were busy, or it came too soon'),
    (_Mark.onset, 'Onset: a sound that crossed the line'),
    (_Mark.signal, 'Onset signal: how sharply the sound rose'),
    (_Mark.threshold, 'The line a sound must cross to count'),
    (_Mark.hitLine, 'The line an onset must reach to be a hit'),
    (_Mark.loudness, 'Loudness'),
    (_Mark.breathing, 'Breathing: waiting for the beat to come back'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (mark, text) in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(width: 28, height: 20, child: CustomPaint(painter: _MarkPainter(mark, theme.colorScheme))),
                const SizedBox(width: 12),
                Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}

enum _Mark { beat, held, hit, dropped, onset, signal, threshold, hitLine, loudness, breathing }

/// One mark of [TraceGuide], in the trace's colours.
class _MarkPainter extends CustomPainter {
  _MarkPainter(this.mark, this.scheme);

  final _Mark mark;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final paint = Paint()..strokeWidth = 2;
    switch (mark) {
      case _Mark.beat || _Mark.held || _Mark.hit || _Mark.dropped:
        final outcome = switch (mark) {
          _Mark.beat => BeatOutcome.fired,
          _Mark.held => BeatOutcome.held,
          _Mark.hit => BeatOutcome.hit,
          _ => BeatOutcome.busy,
        };
        drawBeatMark(canvas, centre, outcome, paint..color = scheme.secondary, Path());
      case _Mark.onset:
        paint.color = scheme.tertiary;
        canvas.drawLine(Offset(centre.dx, size.height), Offset(centre.dx, size.height - 6), paint);
      case _Mark.signal:
        paint.color = scheme.primary;
        for (final (dx, h) in [(-6.0, 6.0), (-2.0, 16.0), (2.0, 4.0), (6.0, 9.0)]) {
          canvas.drawLine(Offset(centre.dx + dx, size.height), Offset(centre.dx + dx, size.height - h), paint);
        }
      case _Mark.threshold:
        paint
          ..color = scheme.error
          ..strokeWidth = 1.5;
        canvas.drawLine(Offset(0, centre.dy), Offset(size.width, centre.dy), paint);
      case _Mark.hitLine:
        paint
          ..color = scheme.tertiary
          ..strokeWidth = 1;
        canvas.drawLine(Offset(0, centre.dy), Offset(size.width, centre.dy), paint);
      case _Mark.loudness:
        canvas.drawRect(Offset.zero & size, Paint()..color = scheme.primary.withValues(alpha: 0.12));
      case _Mark.breathing:
        canvas.drawRect(Offset.zero & size, Paint()..color = scheme.primaryContainer);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.mark != mark || old.scheme != scheme;
}

/// How close the beat is to a lock: confidence and coverage, each against
/// the threshold it must reach. Nothing while music sync is not running.
class LockBars extends StatelessWidget {
  const LockBars({super.key, required this.report});

  final TrackerReport? report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    if (r == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    Widget bar(String name, double value, double needs) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$name ${value.toStringAsFixed(2)} (needs ${needs.toStringAsFixed(2)})', style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          LinearProgressIndicator(
            value: value.clamp(0.0, 1.0),
            color: value >= needs ? theme.colorScheme.primary : theme.colorScheme.outline,
          ),
        ],
      ),
    );
    return Column(
      key: const ValueKey('music-lock-bars'),
      children: [bar('Confidence', r.confidence, r.confidenceNeeded), bar('Coverage', r.coverage, r.coverageNeeded)],
    );
  }
}
